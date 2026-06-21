import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // Browse
    @Published var allSessions: [SessionRef] = []
    @Published var filteredSessions: [SessionRef] = []
    @Published var sourceFilter: SourceFilter = .all { didSet { applyFilter() } }
    @Published var isScanning = false

    // Search
    @Published var query: String = ""
    @Published var mode: SearchMode = .hybrid
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var hasSearched = false

    // Selection / reader
    @Published var selectedPath: String? { didSet { loadTranscript() } }
    @Published var transcript: [TranscriptMessage] = []
    @Published var transcriptTitle: String = ""
    @Published var currentSource: SessionSource = .claude
    @Published var isLoadingTranscript = false

    // Index
    @Published var isIndexing = false
    @Published var statusLine: String = ""

    private let cli = RecallCLI()
    private let store = SessionStore()

    var recallAvailable: Bool { cli.isAvailable }
    var showingResults: Bool { hasSearched && !query.isEmpty }

    // MARK: Browse

    func loadSessions() async {
        isScanning = true
        let store = self.store
        let sessions = await Task.detached(priority: .userInitiated) {
            store.scan()
        }.value
        allSessions = sessions
        applyFilter()
        isScanning = false
        statusLine = "\(sessions.count) sessions"
    }

    func applyFilter() {
        filteredSessions = allSessions.filter { sourceFilter.matches($0.source) }
    }

    // MARK: Search

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        let mode = self.mode
        let source = sourceFilter.cliValue
        isSearching = true
        searchError = nil
        hasSearched = true
        let cli = self.cli
        Task {
            do {
                let res = try await cli.search(query: q, mode: mode, source: source,
                                               project: nil, limit: 50)
                self.results = res
                self.searchError = res.isEmpty ? nil : nil
            } catch {
                self.results = []
                self.searchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.isSearching = false
        }
    }

    func clearSearch() {
        query = ""
        results = []
        searchError = nil
        hasSearched = false
    }

    func fallbackToLexical() {
        mode = .lexical
        runSearch()
    }

    // MARK: Reader

    private func loadTranscript() {
        guard let path = selectedPath else {
            transcript = []
            transcriptTitle = ""
            return
        }
        let source: SessionSource = path.contains("/.codex/") ? .codex : .claude
        currentSource = source
        isLoadingTranscript = true
        let store = self.store
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                store.parseTranscript(path: path, source: source)
            }.value
            // Guard against a newer selection landing first.
            guard self.selectedPath == path else { return }
            self.transcript = parsed.messages
            self.transcriptTitle = parsed.title.isEmpty ? "(untitled)" : parsed.title
            self.isLoadingTranscript = false
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
                await self.loadSessions()
            } catch {
                self.statusLine = "Index failed: " +
                    ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.isIndexing = false
        }
    }
}
