import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.selectedPath == nil {
                ContentUnavailableView("Select a session", systemImage: "text.bubble",
                                       description: Text("Pick a session to read its transcript."))
            } else if app.isLoadingTranscript {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.transcript.isEmpty {
                ContentUnavailableView("Empty transcript", systemImage: "doc",
                                       description: Text("No readable messages in this session."))
            } else {
                transcriptScroll
            }
        }
        .navigationTitle(app.transcriptTitle)
        .toolbar {
            if let path = app.selectedPath {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
        }
    }

    private var transcriptScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(app.transcript) { message in
                    MessageView(message: message, source: app.currentSource)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
    }
}

// MARK: - One message

struct MessageView: View {
    let message: TranscriptMessage
    let source: SessionSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(roleColor)
                    .frame(width: 8, height: 8)
                Text(message.role.displayName(for: source))
                    .font(.headline)
                Spacer()
                if let ts = message.timestamp {
                    Text(ts, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .padding(14)
        .background(roleColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(roleColor.opacity(0.6))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
    }

    private var roleColor: Color {
        switch message.role {
        case .user:      return .accentColor
        case .assistant: return source == .claude ? .orange : .blue
        case .system:    return .gray
        case .tool:      return .purple
        }
    }
}

// MARK: - One content block

struct BlockView: View {
    let block: TranscriptMessage.Block

    var body: some View {
        switch block {
        case .text(let text):
            RichText(text: text)
        case .thinking(let text):
            DisclosureGroup {
                RichText(text: text)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .toolUse(let name, let input):
            DisclosureGroup {
                CodeText(text: input).padding(.top, 4)
            } label: {
                Label("Tool: \(name)", systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
            }
        case .toolResult(let text):
            DisclosureGroup {
                CodeText(text: text).padding(.top, 4)
            } label: {
                Label("Tool result", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Text rendering (prose + fenced code)

/// Renders prose as Markdown and fenced ```code``` spans in a monospaced box.
struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Segment.split(text).enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    CodeText(text: seg.body)
                } else {
                    Text(markdown(seg.body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

struct CodeText: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A run of transcript text, tagged as either prose or a fenced code block.
struct Segment {
    let isCode: Bool
    let body: String

    static func split(_ text: String) -> [Segment] {
        guard text.contains("```") else { return [Segment(isCode: false, body: text)] }
        var segments: [Segment] = []
        var inCode = false
        var current: [String] = []

        func flush() {
            let body = current.joined(separator: "\n")
            if inCode || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(Segment(isCode: inCode, body: body))
            }
            current.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return segments.isEmpty ? [Segment(isCode: false, body: text)] : segments
    }
}
