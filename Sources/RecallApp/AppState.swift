import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {

    // List
    @Published var sessions: [SessionMeta] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var sidebarItem: SidebarItem = .tool(.claude) {   // default view: Claude sessions
        didSet { if sidebarItem != .usage { lastRealFilter = sidebarItem } }
    }
    /// The last non-Usage sidebar filter. The Usage page lives in the detail
    /// column with the sidebar + session list still visible, so the middle list
    /// keeps showing THIS filter's sessions (not a blank list), and selecting a
    /// session restores it.
    var lastRealFilter: SidebarItem = .tool(.claude)
    @Published var searchFocusRequested = false   // ⌘K → focus the search field

    /// Persisted across open/close so reopening Usage is instant (the model's
    /// `loaded` guard skips the refetch).
    let usage = UsageModel()

    // Selection
    @Published var selectedID: String?

    /// A `recall://session/<id>` opened before the index finished loading.
    /// Applied at the end of `load()` so it wins over the auto-select default.
    private var pendingDeepLinkID: String?

    // Glance summary
    @Published var summary: String?
    @Published var summaryLoading = false
    @Published var summaryError: String?

    // Transcript reader (auto-loaded on selection — it's free local parsing).
    // readerItems is the flattened/grouped view model, built off the main thread
    // so the reader never rebuilds it during render or scroll.
    @Published var transcript: [TranscriptMessage] = []
    @Published var readerItems: [ReaderItem] = []
    @Published var transcriptLoading = false

    // Index / status / resume
    @Published var isIndexing = false
    @Published var statusLine = ""
    @Published var resumeNote: String?

    private let cli = RecallCLI()
    private let store = SessionStore()
    private let tarp = TarpLauncher()

    var recallAvailable: Bool { cli.isAvailable }
    var selectedSession: SessionMeta? { sessions.first { $0.sessionID == selectedID } }

    // Facets for the sidebar
    var claudeCount: Int { sessions.lazy.filter { $0.sourceKind == .claude }.count }
    var codexCount: Int { sessions.lazy.filter { $0.sourceKind == .codex }.count }
    var pinnedCount: Int { sessions.lazy.filter { $0.pinned }.count }
    var archivedCount: Int { sessions.lazy.filter { $0.archived }.count }
    var execCount: Int { sessions.lazy.filter { $0.isExec }.count }

    /// Projects present in the index, most-recently-used first.
    var projects: [ProjectFacet] {
        var counts: [String: Int] = [:]
        var last: [String: Int64] = [:]
        for s in sessions where !s.project.isEmpty {
            counts[s.project, default: 0] += 1
            last[s.project] = max(last[s.project] ?? 0, s.lastTs)
        }
        return counts.map { ProjectFacet(path: $0.key, count: $0.value, lastTs: last[$0.key] ?? 0) }
            .sorted { $0.lastTs > $1.lastTs }
    }

    private var weekStartTs: Int64 {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
        return Int64(start.timeIntervalSince1970)
    }
    var recentProjects: [ProjectFacet] { projects.filter { $0.lastTs >= weekStartTs } }
    var olderProjects: [ProjectFacet] { projects.filter { $0.lastTs < weekStartTs } }

    /// Sidebar filter, then the text query.
    func filteredSessions(_ query: String) -> [SessionMeta] {
        var base = sessions
        // In Usage mode keep showing the previous filter's sessions.
        let filter = (sidebarItem == .usage) ? lastRealFilter : sidebarItem
        switch filter {
        case .all:               break
        case .pinned:            base = base.filter { $0.pinned }
        case .archived:          base = base.filter { $0.archived }
        case .automation:        base = base.filter { $0.isExec }
        case .usage:             break   // unreachable (filter is never .usage)
        case .tool(let source):  base = base.filter { $0.sourceKind == source }
        case .project(let path): base = base.filter { $0.project == path }
        }
        // Hide non-interactive exec runs everywhere except their own filter.
        if filter != .automation {
            base = base.filter { !$0.isExec }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            base = base.filter {
                $0.title.lowercased().contains(q) || $0.project.lowercased().contains(q)
            }
        }
        return base
    }

    func groups(_ query: String) -> [SessionGroup] {
        SessionGroup.build(from: filteredSessions(query))
    }

    /// Keyboard nav uses the unfiltered, sidebar-filtered list (search-agnostic
    /// is fine; arrows move within whatever the list currently shows).
    func selectAdjacentIn(_ flat: [SessionMeta], _ delta: Int) {
        guard !flat.isEmpty else { return }
        guard let cur = selectedID,
              let idx = flat.firstIndex(where: { $0.sessionID == cur }) else {
            select(flat[0].sessionID); return
        }
        let next = min(max(idx + delta, 0), flat.count - 1)
        if flat[next].sessionID != cur { select(flat[next].sessionID) }
    }

    // MARK: List

    func load() async {
        isLoading = true
        loadError = nil
        let cli = self.cli
        do {
            // Defensive dedup by sessionID. Duplicate identities (e.g. a stale
            // index that still has sub-agent sidechains sharing a parent's id)
            // don't just look wrong — they corrupt the LazyVStack's ForEach
            // layout and leave blank gaps. Keep first occurrence (newest-first).
            var seen = Set<String>()
            sessions = try await cli.list().filter { seen.insert($0.sessionID).inserted }
            statusLine = "\(sessions.count) sessions"
            // A deep link opened before the index loaded wins over the default.
            if let pending = pendingDeepLinkID {
                pendingDeepLinkID = nil
                applyDeepLink(pending)
            } else if selectedID == nil, let first = groups("").first?.sessions.first {
                // Open the most-recent thread on first load so the reader isn't empty.
                select(first.sessionID)
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    // MARK: Selection

    func select(_ id: String) {
        // Opening a session leaves Usage mode so the detail shows the session.
        if sidebarItem == .usage { sidebarItem = lastRealFilter }
        guard id != selectedID else { return }
        selectedID = id
        summary = nil
        summaryError = nil
        summaryLoading = false
        transcript = []
        readerItems = []
        // Show a cached summary immediately; NEVER auto-spend a codex call.
        // (loadSummary(refresh:) would regenerate when the cache looks stale —
        // which it always does for an actively-growing session, so opening it
        // re-ran codex every time. cachedOnly fetches the last cache and stops.)
        if let s = selectedSession, s.hasSummary {
            loadCachedSummary()
        }
        loadTranscript()
    }

    // MARK: Deep link  (recall://session/<id>)

    /// Entry point for `.onOpenURL`. Selects the linked session, or stashes the
    /// id to apply after the first `load()` when the app is launched cold.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "recall", url.host == "session" else { return }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/" else { return }
        NSApp.activate(ignoringOtherApps: true)
        if sessions.isEmpty {
            pendingDeepLinkID = id
        } else {
            applyDeepLink(id)
        }
    }

    /// Reveal a session by id: switch to a filter that actually contains it (so
    /// its row renders → the highlight and scroll-to can land), then select it.
    private func applyDeepLink(_ id: String) {
        guard let target = sessions.first(where: { $0.sessionID == id }) else {
            statusLine = "Session not found"
            return
        }
        sidebarItem = target.isExec ? .automation : .all
        select(id)
    }

    // MARK: Glance summary

    /// Auto-load path on selection: fetch a cached summary only, no generation,
    /// no "Generating…" state. Leaves summary nil (→ Generate button) on a miss.
    func loadCachedSummary() {
        guard let id = selectedID else { return }
        let cli = self.cli
        Task {
            let result = try? await cli.summary(id, cachedOnly: true)
            guard self.selectedID == id else { return }
            if let s = result?.summary, !s.isEmpty { self.summary = s }
        }
    }

    func loadSummary(refresh: Bool) {
        guard let id = selectedID else { return }
        summaryLoading = true
        summaryError = nil
        let cli = self.cli
        Task {
            do {
                let result = try await cli.summary(id, refresh: refresh)
                guard self.selectedID == id else { return }
                self.summary = result.summary
                // Reflect that this session now has a cached summary.
                await self.load()
            } catch {
                guard self.selectedID == id else { return }
                self.summaryError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            if self.selectedID == id { self.summaryLoading = false }
        }
    }

    // MARK: Transcript

    func loadTranscript() {
        guard let s = selectedSession else { return }
        transcriptLoading = true
        let store = self.store
        let path = s.path
        let source = s.sourceKind
        Task {
            // Parse AND flatten/group into reader items on the background task, so
            // the main thread only receives a ready-to-render array.
            let built = await Task.detached(priority: .userInitiated) {
                () -> (messages: [TranscriptMessage], items: [ReaderItem]) in
                let parsed = store.parseTranscript(path: path, source: source)
                return (parsed.messages, ReaderItem.build(from: parsed.messages))
            }.value
            guard self.selectedID == s.sessionID else { return }
            self.transcript = built.messages
            self.readerItems = built.items
            self.transcriptLoading = false
        }
    }

    // MARK: Pin

    func togglePin(_ session: SessionMeta) {
        let cli = self.cli
        let newValue = !session.pinned
        Task {
            do {
                try await cli.setPinned(session.sessionID, newValue)
                await self.load()
            } catch {
                self.statusLine = "Pin failed: " +
                    ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Resume

    func resume(_ session: SessionMeta) {
        let cli = self.cli
        let tarp = self.tarp
        Task {
            do {
                let info = try await cli.resume(session.sessionID)
                self.resumeNote = tarp.launch(info)
            } catch {
                self.resumeNote = "Resume failed: " +
                    ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Index

    func reindex() {
        guard !isIndexing else { return }
        isIndexing = true
        statusLine = "Indexing…"
        let cli = self.cli
        Task {
            do {
                try await cli.index { line in
                    Task { @MainActor in self.statusLine = line }
                }
                self.statusLine = "Index updated"
                await self.load()
            } catch {
                self.statusLine = "Index failed: " +
                    ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.isIndexing = false
        }
    }
}
