import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            TranscriptView()
        }
        .task {
            if app.allSessions.isEmpty { await app.loadSessions() }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppState

    private var selection: Binding<SourceFilter?> {
        Binding(get: { app.sourceFilter },
                set: { app.sourceFilter = $0 ?? .all })
    }

    var body: some View {
        List(selection: selection) {
            Section("Sources") {
                Label("All Sessions", systemImage: "tray.full")
                    .tag(SourceFilter.all)
                Label("Claude Code", systemImage: "sparkles")
                    .tag(SourceFilter.claude)
                Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    .tag(SourceFilter.codex)
            }
        }
        .navigationTitle("Recall")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if !app.recallAvailable {
                    Label("recall CLI not found", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    if app.isIndexing || app.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(app.statusLine.isEmpty ? "\(app.filteredSessions.count) shown" : app.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button {
                    app.reindex()
                } label: {
                    Label("Reindex", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(app.isIndexing || !app.recallAvailable)
            }
            .padding(10)
        }
    }
}
