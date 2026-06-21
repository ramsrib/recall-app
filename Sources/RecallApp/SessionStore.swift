import Foundation

/// Reads session transcripts directly off disk — used for browsing the full
/// list and for rendering a selected session. Mirrors recall's adapters:
///   Claude → ~/.claude/projects/**/*.jsonl
///   Codex  → ~/.codex/{sessions,archived_sessions}/**/rollout-*.jsonl
struct SessionStore: Sendable {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: Discovery (cheap metadata pass for the browse list)

    func scan() -> [SessionRef] {
        var refs = scanClaude()
        refs.append(contentsOf: scanCodex())
        return refs.sorted { $0.modified > $1.modified }
    }

    private func scanClaude() -> [SessionRef] {
        let root = "\(home)/.claude/projects"
        return jsonlFiles(under: root) { name in name.hasSuffix(".jsonl") }
            .compactMap { url in
                let head = readHead(url)
                let meta = claudeMeta(from: head, fallbackDir: url.deletingLastPathComponent().lastPathComponent)
                return SessionRef(
                    path: url.path,
                    source: .claude,
                    sessionID: meta.sessionID ?? url.deletingPathExtension().lastPathComponent,
                    project: meta.project ?? decodeClaudeDir(url.deletingLastPathComponent().lastPathComponent),
                    title: meta.title ?? "(untitled)",
                    modified: modificationDate(url)
                )
            }
    }

    private func scanCodex() -> [SessionRef] {
        var refs: [SessionRef] = []
        for dir in ["\(home)/.codex/sessions", "\(home)/.codex/archived_sessions"] {
            refs.append(contentsOf:
                jsonlFiles(under: dir) { name in
                    name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
                }
                .compactMap { url in
                    let head = readHead(url)
                    let meta = codexMeta(from: head)
                    return SessionRef(
                        path: url.path,
                        source: .codex,
                        sessionID: meta.sessionID ?? url.deletingPathExtension().lastPathComponent,
                        project: meta.project ?? "",
                        title: meta.title ?? "(untitled)",
                        modified: modificationDate(url)
                    )
                }
            )
        }
        return refs
    }

    // MARK: Full transcript parse (on selection)

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

    // MARK: Claude parsing

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
        messages.append(TranscriptMessage(
            role: TranscriptMessage.Role(rawValue: roleStr) ?? .assistant,
            blocks: blocks,
            timestamp: parseISO(obj["timestamp"] as? String)
        ))
    }

    private func claudeBlocks(_ content: Any?) -> [TranscriptMessage.Block] {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.text(s)]
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

    private func claudeMeta(from head: String, fallbackDir: String)
        -> (sessionID: String?, project: String?, title: String?) {
        var sessionID: String?
        var project: String?
        var title: String?
        var firstUserLine: String?
        head.enumerateLines { line, stop in
            guard let obj = jsonObject(line) else { return }
            let type = obj["type"] as? String
            if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                title = t
            }
            if sessionID == nil { sessionID = obj["sessionId"] as? String }
            if project == nil { project = obj["cwd"] as? String }
            if firstUserLine == nil, type == "user",
               let m = obj["message"] as? [String: Any] {
                firstUserLine = firstLine(claudeBlocks(m["content"]))
            }
            if title != nil && project != nil { stop = true }
        }
        return (sessionID, project, title ?? firstUserLine)
    }

    // MARK: Codex parsing

    private func parseCodexLine(_ obj: [String: Any],
                                into messages: inout [TranscriptMessage],
                                title: inout String) {
        guard let type = obj["type"] as? String else { return }
        guard type == "response_item",
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "message",
              let roleStr = payload["role"] as? String,
              roleStr == "user" || roleStr == "assistant" else { return }
        let parts = (payload["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
            .filter { !$0.isEmpty } ?? []
        let text = parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(TranscriptMessage(
            role: TranscriptMessage.Role(rawValue: roleStr) ?? .user,
            blocks: [.text(text)],
            timestamp: nil
        ))
    }

    private func codexMeta(from head: String)
        -> (sessionID: String?, project: String?, title: String?) {
        var sessionID: String?
        var project: String?
        var title: String?
        head.enumerateLines { line, stop in
            guard let obj = jsonObject(line), let type = obj["type"] as? String else { return }
            if type == "session_meta", let p = obj["payload"] as? [String: Any] {
                sessionID = p["id"] as? String
                project = p["cwd"] as? String
            }
            if type == "response_item", title == nil,
               let p = obj["payload"] as? [String: Any],
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user" {
                let parts = (p["content"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String } ?? []
                let t = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("<") {
                    title = String(t.prefix(80))
                }
            }
            if title != nil && project != nil { stop = true }
        }
        return (sessionID, project, title)
    }

    // MARK: Filesystem helpers

    private func jsonlFiles(under root: String, where matches: (String) -> Bool) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        let rootURL = URL(fileURLWithPath: root)
        guard let en = fm.enumerator(at: rootURL,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in en where matches(url.lastPathComponent) {
            urls.append(url)
        }
        return urls
    }

    /// Reads only the first 64 KB — enough for title/project metadata without
    /// pulling a multi-megabyte transcript into memory just to list it.
    private func readHead(_ url: URL, bytes: Int = 64 * 1024) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }

    private func decodeClaudeDir(_ name: String) -> String {
        // "-Users-you-Projects-dotfiles" → "/Users/you/Projects/dotfiles"
        // Ambiguous for project names containing dashes, but fine as a label.
        name.replacingOccurrences(of: "-", with: "/")
    }

    private func firstLine(_ blocks: [TranscriptMessage.Block]) -> String? {
        for case let .text(t) in blocks {
            let line = t.split(separator: "\n").first.map(String.init) ?? t
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return nil
    }

    private func derivedTitle(_ messages: [TranscriptMessage]) -> String {
        for m in messages where m.role == .user {
            if let line = firstLine(m.blocks) { return line }
        }
        return "(untitled)"
    }
}

// MARK: - Free helpers

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func stringify(_ value: Any?) -> String {
    switch value {
    case let s as String:
        return s
    case let arr as [[String: Any]]:
        // tool_result content is often [{type:"text", text:"..."}]
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
