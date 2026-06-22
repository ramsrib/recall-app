import Foundation

/// Parses a single transcript off disk for the reader view. (Listing/metadata is
/// the CLI's job via `recall list`; this is only the full read on demand.)
struct SessionStore: Sendable {

    func parseTranscript(path: String, source: SessionSource) -> ParsedTranscript {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ParsedTranscript(title: "", messages: [])
        }
        let text = String(decoding: data, as: UTF8.self)
        var messages: [TranscriptMessage] = []
        var title = ""
        text.enumerateLines { line, _ in
            guard let obj = jsonObject(line) else { return }
            switch source {
            case .claude: parseClaudeLine(obj, into: &messages, title: &title)
            case .codex:  parseCodexLine(obj, into: &messages, title: &title)
            }
        }
        if title.isEmpty { title = derivedTitle(messages) }
        return ParsedTranscript(title: title, messages: messages)
    }

    // MARK: Claude

    private func parseClaudeLine(_ obj: [String: Any],
                                 into messages: inout [TranscriptMessage],
                                 title: inout String) {
        let type = obj["type"] as? String
        if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
            title = t
            return
        }
        guard type == "user" || type == "assistant",
              let message = obj["message"] as? [String: Any] else { return }
        let roleStr = (message["role"] as? String) ?? type ?? "assistant"
        let blocks = claudeBlocks(message["content"])
        guard !blocks.isEmpty else { return }
        if roleStr == "user", isInjectedContext(textOf(blocks)) { return }
        messages.append(TranscriptMessage(
            role: TranscriptMessage.Role(rawValue: roleStr) ?? .assistant,
            blocks: blocks,
            timestamp: parseISO(obj["timestamp"] as? String)
        ))
    }

    private func claudeBlocks(_ content: Any?) -> [TranscriptMessage.Block] {
        if let s = content as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(s)]
        }
        guard let arr = content as? [[String: Any]] else { return [] }
        var blocks: [TranscriptMessage.Block] = []
        for b in arr {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !t.isEmpty { blocks.append(.text(t)) }
            case "thinking":
                if let t = b["thinking"] as? String, !t.isEmpty { blocks.append(.thinking(t)) }
            case "tool_use":
                let name = (b["name"] as? String) ?? "tool"
                blocks.append(.toolUse(name: name, input: stringify(b["input"])))
            case "tool_result":
                let body = stringify(b["content"])
                if !body.isEmpty { blocks.append(.toolResult(body)) }
            default:
                break
            }
        }
        return blocks
    }

    // MARK: Codex

    private func parseCodexLine(_ obj: [String: Any],
                                into messages: inout [TranscriptMessage],
                                title: inout String) {
        guard (obj["type"] as? String) == "response_item",
              let payload = obj["payload"] as? [String: Any] else { return }
        let ts = parseISO(obj["timestamp"] as? String)

        switch payload["type"] as? String {
        case "message":
            guard let roleStr = payload["role"] as? String,
                  roleStr == "user" || roleStr == "assistant" else { return }
            let parts = (payload["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .filter { !$0.isEmpty } ?? []
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if roleStr == "user", isInjectedContext(text) { return }
            messages.append(TranscriptMessage(
                role: TranscriptMessage.Role(rawValue: roleStr) ?? .user,
                blocks: [.text(text)], timestamp: ts))

        case "function_call", "tool_search_call":
            let name = (payload["name"] as? String) ?? "tool"
            let args = (payload["arguments"] as? String) ?? stringify(payload["arguments"])
            messages.append(TranscriptMessage(
                role: .assistant, blocks: [.toolUse(name: name, input: args)], timestamp: nil))

        case "function_call_output", "tool_search_output":
            let out = (payload["output"] as? String) ?? stringify(payload["output"])
            guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            messages.append(TranscriptMessage(
                role: .tool, blocks: [.toolResult(out)], timestamp: nil))

        case "reasoning":
            // Codex usually encrypts reasoning; a plaintext summary is rare.
            let summary = (payload["summary"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String } ?? []
            let txt = summary.joined(separator: "\n")
            if !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(TranscriptMessage(
                    role: .assistant, blocks: [.thinking(txt)], timestamp: nil))
            }

        default:
            return
        }
    }

    private func derivedTitle(_ messages: [TranscriptMessage]) -> String {
        for m in messages where m.role == .user {
            for case let .text(t) in m.blocks {
                let line = t.split(separator: "\n").first.map(String.init) ?? t
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
            }
        }
        return "(untitled)"
    }
}

// MARK: - Free helpers

private func textOf(_ blocks: [TranscriptMessage.Block]) -> String {
    blocks.compactMap { if case let .text(t) = $0 { return t } else { return nil } }
        .joined(separator: "\n")
}

/// True for harness-injected "user" messages (CLAUDE.md/AGENTS.md, environment,
/// permissions, system reminders, slash-command expansions) — noise in a reader.
private func isInjectedContext(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return false }
    let markers = [
        "# AGENTS.md", "<INSTRUCTIONS>", "<environment_context>", "<permissions",
        "<user_instructions>", "<system-reminder>", "<command-name>", "<command-message>",
        "<local-command-stdout>", "Caveat: The messages below were generated by the user",
    ]
    return markers.contains { t.hasPrefix($0) }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func stringify(_ value: Any?) -> String {
    switch value {
    case let s as String:
        return s
    case let arr as [[String: Any]]:
        let texts = arr.compactMap { $0["text"] as? String }
        if !texts.isEmpty { return texts.joined(separator: "\n") }
        fallthrough
    default:
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    return isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
}
