import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            searchControls
            Divider()
            if let err = app.searchError {
                errorBanner(err)
            }
            listBody
        }
        .navigationTitle(app.showingResults ? "Results" : "Sessions")
    }

    // MARK: Search controls

    private var searchControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions…", text: $app.query)
                    .textFieldStyle(.plain)
                    .onSubmit { app.runSearch() }
                if app.isSearching {
                    ProgressView().controlSize(.small)
                } else if !app.query.isEmpty {
                    Button {
                        app.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Picker("Mode", selection: $app.mode) {
                ForEach(SearchMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: app.mode) { _, _ in
                if app.hasSearched { app.runSearch() }
            }
        }
        .padding(10)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.primary)
            if app.mode.needsOllama {
                Button("Search lexically instead") { app.fallbackToLexical() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.yellow.opacity(0.15))
    }

    // MARK: List

    @ViewBuilder
    private var listBody: some View {
        if app.showingResults {
            if app.results.isEmpty && !app.isSearching {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                       description: Text("Nothing found for “\(app.query)”."))
            } else {
                List(selection: $app.selectedPath) {
                    ForEach(Array(app.results.enumerated()), id: \.offset) { _, r in
                        ResultRow(result: r)
                            .tag(r.path)
                    }
                }
            }
        } else {
            if app.filteredSessions.isEmpty && !app.isScanning {
                ContentUnavailableView("No sessions", systemImage: "tray",
                                       description: Text("No transcripts found on disk."))
            } else {
                List(selection: $app.selectedPath) {
                    ForEach(app.filteredSessions) { s in
                        SessionRow(session: s)
                            .tag(s.path)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

struct SessionRow: View {
    let session: SessionRef

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                SourceBadge(source: session.source)
                Text(session.projectName)
                    .lineLimit(1)
                Spacer()
                Text(session.modified, format: .relative(presentation: .named))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.title.isEmpty ? "(untitled)" : result.title)
                .font(.body)
                .lineLimit(1)
            Text(result.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                SourceBadge(source: result.sourceKind)
                Text(result.projectName).lineLimit(1)
                Spacer()
                if let d = result.date {
                    Text(d, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct SourceBadge: View {
    let source: SessionSource

    var body: some View {
        Text(source.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        source == .claude ? .orange : .blue
    }
}
