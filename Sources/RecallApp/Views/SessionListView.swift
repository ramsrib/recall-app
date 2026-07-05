import SwiftUI
import AppKit

/// Search text in isolation. Held by SessionListView via @State (NOT observed),
/// so typing re-renders only SessionListContent (which @ObservedObject's it),
/// never the toolbar host — that's what keeps the NSSearchField from being
/// recreated and losing focus on every keystroke.
final class SearchModel: ObservableObject {
    @Published var text = ""
}

struct SessionListView: View {
    @EnvironmentObject var app: AppState
    @State private var search = SearchModel()     // @State = hold, don't observe
    @State private var searchPresented = false

    private var searchBinding: Binding<String> {
        Binding(get: { search.text }, set: { search.text = $0 })
    }

    var body: some View {
        SessionListContent(search: search)
            .background(Color(nsColor: .windowBackgroundColor))
            // Apple's native search field — the only reliable toolbar search
            // (it survives the list re-rendering). Apple places it top-right.
            .searchable(text: searchBinding, isPresented: $searchPresented,
                        placement: .toolbar, prompt: "Search title or project")
            .onChange(of: app.searchFocusRequested) { _, req in   // ⌘K
                if req { searchPresented = true; app.searchFocusRequested = false }
            }
    }
}

struct SessionListContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var search: SearchModel
    @FocusState private var listFocused: Bool
    @State private var olderShown = 0

    var body: some View {
        // Compute the grouping ONCE per render. These were separate computed
        // properties, so each render re-ran app.groups() (re-filtering every
        // session) 5–6× — wasteful on every keystroke and as the index grows.
        let groups = app.groups(search.text)
        let olderTotal = groups.first { $0.bucket == .older }?.sessions.count ?? 0
        let recentCount = groups.filter { $0.bucket != .older }.reduce(0) { $0 + $1.sessions.count }
        let effectiveOlderShown = (recentCount == 0 && olderShown == 0) ? 10 : olderShown
        let displayGroups: [SessionGroup] = groups.compactMap { g in
            guard g.bucket == .older else { return g }
            let shown = Array(g.sessions.prefix(effectiveOlderShown))
            return shown.isEmpty ? nil : SessionGroup(bucket: .older, sessions: shown)
        }
        let flat = displayGroups.flatMap { $0.sessions }

        return Group {
            if let err = app.loadError {
                errorState(err)
            } else if app.sessions.isEmpty && app.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text(search.text.isEmpty
                        ? "Nothing in this filter."
                        : "Nothing matches “\(search.text)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listBody(displayGroups: displayGroups, flat: flat,
                         olderTotal: olderTotal, effectiveOlderShown: effectiveOlderShown)
            }
        }
        .onChange(of: app.sidebarItem) { _, _ in olderShown = 0 }
        .onChange(of: search.text) { _, _ in olderShown = 0 }
    }

    private func listBody(displayGroups: [SessionGroup], flat: [SessionMeta],
                          olderTotal: Int, effectiveOlderShown: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(displayGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session)
                                    .id(session.sessionID)
                                    .onTapGesture { app.select(session.sessionID); listFocused = true }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                    if effectiveOlderShown < olderTotal {
                        Button {
                            olderShown = effectiveOlderShown + 10
                        } label: {
                            Label("Load \(min(10, olderTotal - effectiveOlderShown)) more",
                                  systemImage: "ellipsis")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up:   app.selectAdjacentIn(flat, -1)
                case .down: app.selectAdjacentIn(flat, 1)
                default:    break
                }
            }
            .onChange(of: app.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func groupHeader(_ group: SessionGroup) -> some View {
        HStack(spacing: 6) {
            if group.bucket == .pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            if group.bucket == .parked { Image(systemName: "pause.circle.fill").font(.system(size: 9)) }
            Text(group.bucket.rawValue.uppercased())
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await app.load() } }
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

struct SessionRow: View {
    @EnvironmentObject var app: AppState
    let session: SessionMeta
    @State private var hovering = false

    // Derive selection live from the shared state instead of receiving it as a
    // frozen `let` from the parent. In a LazyVStack with pinned section headers,
    // the parent's ForEach builder isn't reliably re-run for rows whose identity
    // is unchanged, so a passed-in `selected` goes stale and the first
    // (auto-selected) row stays highlighted alongside a newly-tapped one. Reading
    // `app.selectedID` here means every selection change re-renders each row with
    // a fresh value — exactly one row can be selected.
    private var selected: Bool { app.selectedID == session.sessionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                pinButton.opacity(session.pinned || hovering ? 1 : 0)
            }
            HStack(spacing: 6) {
                SourceBadge(source: session.sourceKind)
                if session.isExec { TagBadge(text: "AUTOMATION") }
                if session.archived { TagBadge(text: "ARCHIVED") }
                Text(session.projectName).lineLimit(1)
                if session.hasSummary { Image(systemName: "sparkles").font(.system(size: 9)) }
                if app.parkedSessionIDs.contains(session.sessionID) {
                    Image(systemName: "pause.circle").font(.system(size: 9)).help("Parked session")
                }
                if app.mentesSessionIDs.contains(session.sessionID) {
                    Image(systemName: "checklist").font(.system(size: 9)).help("Has Mentes tasks")
                }
                Spacer(minLength: 4)
                Text(session.lastDate, format: .relative(presentation: .named))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Session ID") { setClipboard(session.sessionID) }
            Button("Copy Link") { setClipboard("recall://session/\(session.sessionID)") }
            Divider()
            Button(session.pinned ? "Unpin" : "Pin") { app.togglePin(session) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
            }
        }
    }

    private func setClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var rowBackground: Color {
        if selected { return .selectionFill }
        if hovering { return Color.primary.opacity(0.035) }
        return .clear
    }

    private var pinButton: some View {
        Button { app.togglePin(session) } label: {
            Image(systemName: session.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(session.pinned ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(session.pinned ? "Unpin" : "Pin")
    }
}

struct SourceBadge: View {
    let source: SessionSource
    var body: some View {
        Text(source.displayName.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct TagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}
