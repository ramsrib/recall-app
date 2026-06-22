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

/// Read-only session title for the toolbar center — like an address bar showing
/// the current page. Search is the native `.searchable` field, so there is no
/// editable-field / focus logic here at all (that's what kept breaking).
struct OmniBar: View {
    @EnvironmentObject var app: AppState

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
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: 460)
            } else {
                Text("Recall")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            }
        }
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

    private var selection: Binding<SidebarItem?> {
        Binding(get: { app.sidebarItem }, set: { if let v = $0 { app.sidebarItem = v } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("All Sessions", systemImage: "tray.full").tag(SidebarItem.all)
                Label("Pinned", systemImage: "pin").tag(SidebarItem.pinned)
                if app.archivedCount > 0 {
                    Label("Archived", systemImage: "archivebox").tag(SidebarItem.archived)
                }
                if app.execCount > 0 {
                    Label("Automation", systemImage: "terminal").tag(SidebarItem.automation)
                }
                Label("Usage", systemImage: "chart.pie").tag(SidebarItem.usage)
            }
            Section("Tools") {
                Label("Claude", systemImage: "sparkles").tag(SidebarItem.tool(.claude))
                Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    .tag(SidebarItem.tool(.codex))
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
        Label(p.name, systemImage: "folder")
            .tag(SidebarItem.project(p.path))
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
