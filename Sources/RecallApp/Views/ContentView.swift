import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            FilterSidebar()                          // owns the reindex toolbar item
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            SessionListView()                       // owns the search toolbar item
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            // Usage takes over only the detail column — the sidebar + session
            // list stay put (no window-level swap, layout/toolbar untouched).
            if app.sidebarItem == .usage {
                UsageView(model: app.usage)
            } else {
                DetailView()                        // owns the title + actions toolbar items
            }
        }
        .tint(.primary)   // black caret / selection instead of accent blue
        .task {
            if app.sessions.isEmpty { await app.load() }
        }
        // Refresh when the app regains focus — `recall list` now reconciles with
        // disk cheaply (warm ~25ms), so new Claude/Codex sessions appear without
        // a manual reindex. Selection is preserved across the reload.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await app.load() }
        }
    }
}

/// Read-only session title — like an address bar showing the current page. It
/// reads as a tab hanging off the window's top edge (square at the top, rounded
/// below) and fades away once the detail pane is scrolled: the title is
/// orientation for the page you just opened, not a permanent fixture.
///
/// DetailView draws it as a top overlay rather than a `ToolbarItem`. As a
/// toolbar item the system paints its own fixed-width capsule that the title
/// spilled out of, and hiding that capsule
/// (`sharedBackgroundVisibility(.hidden)`) turned the whole toolbar band opaque
/// gray. Search is a separate collapsing toolbar control, so there's no
/// editable-field / focus logic here at all (that's what kept breaking).
struct OmniBar: View {
    @EnvironmentObject var app: AppState

    private static let cornerRadius: CGFloat = 18
    private static let maxWidth: CGFloat = 620
    private static let hPadding: CGFloat = 26

    var body: some View {
        Group {
            if let s = app.selectedSession {
                VStack(spacing: 2) {
                    Text(s.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle(s))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Width is measured, not `maxWidth:` — a flexible frame fills
                // all 620pt even for a three-word title, leaving a wide empty
                // plate. This hugs the text and caps long titles (which then
                // truncate inside).
                .frame(width: plateWidth(title: s.displayTitle, subtitle: subtitle(s)))
            } else {
                Text("Recall")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Self.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .background {
            let plate = UnevenRoundedRectangle(topLeadingRadius: 0,
                                               bottomLeadingRadius: Self.cornerRadius,
                                               bottomTrailingRadius: Self.cornerRadius,
                                               topTrailingRadius: 0,
                                               style: .continuous)
            plate
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay { plate.strokeBorder(Color.hairline, lineWidth: 1) }
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .transition(.opacity)
    }

    /// Ideal text width, capped — measured with the same fonts the labels use.
    private func plateWidth(title: String, subtitle: String) -> CGFloat {
        let titleWidth = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).size().width
        let subtitleWidth = NSAttributedString(
            string: subtitle,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width
        return min(ceil(max(titleWidth, subtitleWidth)) + 1, Self.maxWidth - 2 * Self.hPadding)
    }

    private func subtitle(_ s: SessionMeta) -> String {
        var parts = [s.sourceKind.displayName, s.projectName, "\(s.msgCount) messages"]
        if s.archived { parts.append("Archived") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Filter sidebar (search lives in the list column; this is quick filters)

struct FilterSidebar: View {
    @EnvironmentObject var app: AppState
    @State private var projectsShown = 0

    var body: some View {
        // No `List(selection:)` — its native focused highlight paints a harsh
        // bright fill in dark mode (primary tint → white). SidebarRow draws a
        // custom, focus-independent selection using the app's theme tokens.
        List {
            Section("Library") {
                SidebarRow(item: .all)    { Label("All Sessions", systemImage: "tray.full") }
                SidebarRow(item: .pinned) { Label("Pinned", systemImage: "pin") }
                if app.parkedCount > 0 {
                    SidebarRow(item: .parked) { Label("Parked", systemImage: "pause.circle") }
                }
                if app.archivedCount > 0 {
                    SidebarRow(item: .archived) { Label("Archived", systemImage: "archivebox") }
                }
                if app.execCount > 0 {
                    SidebarRow(item: .automation) { Label("Automation", systemImage: "terminal") }
                }
                SidebarRow(item: .usage) { Label("Usage", systemImage: "chart.pie") }
            }
            Section("Tools") {
                SidebarRow(item: .tool(.claude)) {
                    Label { Text("Claude") } icon: { SourceIcon(source: .claude) }
                }
                SidebarRow(item: .tool(.codex)) {
                    Label { Text("Codex") } icon: { SourceIcon(source: .codex) }
                }
            }
            Section("Projects") {
                ForEach(app.recentProjects) { projectRow($0) }
                ForEach(app.olderProjects.prefix(projectsShown)) { projectRow($0) }
                if projectsShown < app.olderProjects.count {
                    Button {
                        projectsShown += 10
                    } label: {
                        Label("Load more", systemImage: "ellipsis")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 10))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .tint(.primary)
        // Only a transient status strip while indexing — the reindex action now
        // lives in the window toolbar.
        .safeAreaInset(edge: .bottom) { if app.isIndexing { footer } }
        // Reindex inside the sidebar header, next to the native toggle (which
        // lives at the sidebar's trailing edge → .primaryAction).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.reindex() } label: {
                    if app.isIndexing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Reindex sessions (⌘⇧R)")
                .disabled(app.isIndexing || !app.recallAvailable)
            }
        }
    }

    private func projectRow(_ p: ProjectFacet) -> some View {
        SidebarRow(item: .project(p.path)) {
            Label(p.name, systemImage: "folder")
        }
        .help(p.path)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.hairline)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(app.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

// MARK: - Sidebar filter row

/// A sidebar filter row with a custom, focus-independent selection style — a
/// subtle fill + hairline border using the app's theme tokens. Replaces the
/// native `List(selection:)` highlight, which in dark mode paints a harsh bright
/// fill when the sidebar is focused (the `.primary` tint resolves to white).
private struct SidebarRow<Content: View>: View {
    @EnvironmentObject var app: AppState
    let item: SidebarItem
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        let selected = app.sidebarItem == item
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.selectionFill
                                   : (hovering ? Color.primary.opacity(0.05) : Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.hairline : Color.clear, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { app.sidebarItem = item }
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
