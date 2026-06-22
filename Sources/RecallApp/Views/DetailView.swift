import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if let session = app.selectedSession {
                detail(session)
            } else {
                ContentUnavailableView("Select a session", systemImage: "text.bubble",
                                       description: Text("Pick a thread to read, summarize, or resume."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            // Title + actions live in the detail column's toolbar region.
            ToolbarItem(placement: .principal) { OmniBar() }
            ToolbarItemGroup(placement: .primaryAction) {
                if let s = app.selectedSession {
                    Button { app.resume(s) } label: { Label("Resume", systemImage: "play.fill") }
                        .disabled(!app.recallAvailable)
                    Button { app.togglePin(s) } label: {
                        Image(systemName: s.pinned ? "pin.fill" : "pin")
                    }
                    .help(s.pinned ? "Unpin" : "Pin")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                }
            }
        }
    }

    private func detail(_ s: SessionMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let note = app.resumeNote { resumeBanner(note) }
                glanceSection
                Divider().overlay(Color.hairline)
                transcriptSection(s)
            }
            .frame(maxWidth: Theme.readerMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)            // center the reading column
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
    }

    private func resumeBanner(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { app.resumeNote = nil } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    // MARK: Glance

    @ViewBuilder
    private var glanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Summary")
                Spacer()
                if app.summary != nil && !app.summaryLoading {
                    Button("Regenerate") { app.loadSummary(refresh: true) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }

            if app.summaryLoading {
                glanceCardWrapper {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating summary via codex…").foregroundStyle(.secondary).font(.callout)
                    }
                }
            } else if let summary = app.summary {
                GlanceCard(text: summary)
            } else if let err = app.summaryError {
                glanceCardWrapper {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err).font(.callout).foregroundStyle(.secondary)
                        Button("Try again") { app.loadSummary(refresh: false) }.controlSize(.small)
                    }
                }
            } else {
                Button { app.loadSummary(refresh: false) } label: {
                    Label("Generate summary", systemImage: "sparkles")
                }
            }
        }
    }

    private func glanceCardWrapper<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }

    // MARK: Transcript (auto-loaded)

    @ViewBuilder
    private func transcriptSection(_ s: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Recent Messages")
            if app.transcriptLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if app.readerItems.isEmpty {
                Text("No readable messages — the transcript file may have moved (try Reindex).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // .id resets the reader's window (and scroll) when the session changes.
                TranscriptReader(items: app.readerItems).id(s.sessionID)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Glance card (light formatting of the codex summary)

struct GlanceCard: View {
    let text: String
    private static let labels: Set<String> = ["Gist", "Topics", "Started", "Ended"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .lineSpacing(3)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
        .textSelection(.enabled)
    }

    private var lines: [String] { text.components(separatedBy: "\n") }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Color.clear.frame(height: 2)
        } else if t.hasPrefix("- ") || t.hasPrefix("• ") {
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                Text(String(t.dropFirst(2))).foregroundStyle(.primary)
            }
            .font(.system(size: 14))
        } else if let label = leadingLabel(t) {
            let rest = String(t.dropFirst(label.count))
            (Text(label).fontWeight(.semibold) + Text(rest)).font(.system(size: 14))
        } else {
            Text(t).font(.system(size: 14))
        }
    }

    private func leadingLabel(_ s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let word = String(s[s.startIndex..<colon])
        return Self.labels.contains(word) ? word + ":" : nil
    }
}
