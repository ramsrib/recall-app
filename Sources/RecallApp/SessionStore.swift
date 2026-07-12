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
        var stats = InsightsAccumulator()
        text.enumerateLines { line, _ in
            guard let obj = jsonObject(line) else { return }
            switch source {
            case .claude:
                stats.ingestClaude(obj)
                parseClaudeLine(obj, into: &messages, title: &title)
            case .codex:
                stats.ingestCodex(obj)
                parseCodexLine(obj, into: &messages, title: &title)
            }
        }
        if title.isEmpty { title = derivedTitle(messages) }
        return ParsedTranscript(title: title, messages: messages, insights: stats.finish(source: source))
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

    // MARK: Task sidecar

    /// Whether a session has a `.mentes.jsonl` sidecar next to its transcript.
    /// A pure existence check — the file is NOT read; this just drives the list
    /// badge. The details are read on open via `mentesTasks`.
    func hasMentesSidecar(forTranscript path: String) -> Bool {
        FileManager.default.fileExists(atPath: mentesSidecarPath(path))
    }

    /// Read the `.mentes.jsonl` sidecar and return the distinct tasks it lists,
    /// newest activity first. Read on session open, never during listing. Empty
    /// when there's no sidecar — which is the normal case.
    func mentesTasks(forTranscript path: String) -> [MentesTask] {
        guard let data = FileManager.default.contents(atPath: mentesSidecarPath(path)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        struct Agg { var action: String; var date: Date; var events: Int; var order: Int }
        var byID: [String: Agg] = [:]
        var order = 0
        text.enumerateLines { line, _ in
            guard let obj = jsonObject(line),
                  let taskID = obj["task_id"] as? String, !taskID.isEmpty else { return }
            let action = (obj["action"] as? String) ?? ""
            let date = parseMentesTs(obj["ts"] as? String)
            if var a = byID[taskID] {
                a.events += 1
                if date >= a.date { a.date = date; a.action = action }  // latest wins
                byID[taskID] = a
            } else {
                byID[taskID] = Agg(action: action, date: date, events: 1, order: order)
                order += 1
            }
        }
        return byID.map { id, a in
            // The companion task app, if installed, registers this URL scheme.
            MentesTask(taskID: id, action: a.action, date: a.date, events: a.events,
                       mentesURL: "mentes-tasks://tasks/\(id)")
        }
        .sorted {
            $0.date != $1.date ? $0.date > $1.date
                               : byID[$0.taskID]!.order < byID[$1.taskID]!.order
        }
    }

    private func mentesSidecarPath(_ transcriptPath: String) -> String {
        // <transcript>.jsonl → <transcript>.mentes.jsonl — the transcript's own
        // basename, not the session id (they differ for Codex rollout files).
        return siblingPath(transcriptPath, suffix: ".mentes.jsonl")
    }

    // MARK: Park marker

    /// Read the `.park.json` marker sitting next to a session's transcript, or nil
    /// when the session isn't parked (no marker, or an aborted empty `{}` one).
    /// Cheap — a tiny single-object JSON file. Used both to badge the list (see
    /// AppState) and to show park status on open.
    func parkMarker(forTranscript path: String) -> ParkMarker? {
        guard let data = FileManager.default.contents(atPath: parkMarkerPath(path)),
              let marker = try? JSONDecoder().decode(ParkMarker.self, from: data),
              marker.isParked else { return nil }
        return marker
    }

    private func parkMarkerPath(_ transcriptPath: String) -> String {
        // <transcript>.jsonl → <transcript>.park.json (sibling of the transcript)
        return siblingPath(transcriptPath, suffix: ".park.json")
    }

    private func siblingPath(_ transcriptPath: String, suffix: String) -> String {
        let base = transcriptPath.hasSuffix(".jsonl")
            ? String(transcriptPath.dropLast(6)) : transcriptPath
        return base + suffix
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

// MARK: - Insights accumulator (model + token totals, single-pass over the file)

/// Accumulates model + token usage while `parseTranscript` walks the JSONL, so
/// the stats come for free from the read the reader already does. Kept separate
/// from the message-building pass because it must see lines the reader skips
/// (assistant lines with no renderable blocks, Codex `token_count` events, …).
private struct InsightsAccumulator {
    private var modelOrder: [String] = []
    private var modelTurns: [String: Int] = [:]
    private var seenUsage = Set<String>()
    // Claude: per-message usage summed across the session (cache tracked apart).
    private var input = 0, output = 0, cacheRead = 0, cacheCreate = 0, turns = 0
    // Codex: `token_count.total_token_usage` is already cumulative — keep latest.
    private var codexInput = 0, codexCached = 0, codexOutput = 0
    private var codexTotal: Int?
    private var contextWindow: Int?
    private var cliVersion: String?

    mutating func ingestClaude(_ obj: [String: Any]) {
        if cliVersion == nil, let v = obj["version"] as? String, !v.isEmpty { cliVersion = v }
        guard (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any] else { return }
        // A streamed assistant message can be logged more than once; dedupe on the
        // (requestId, message.id) pair so tokens aren't counted twice (ccusage keys
        // on the same pair).
        if let id = msg["id"] as? String {
            let key = ((obj["requestId"] as? String) ?? "") + "|" + id
            if !seenUsage.insert(key).inserted { return }
        }
        if let m = msg["model"] as? String, !m.isEmpty, !m.hasPrefix("<") { note(m) }
        turns += 1
        guard let u = msg["usage"] as? [String: Any] else { return }
        input += (u["input_tokens"] as? Int) ?? 0
        output += (u["output_tokens"] as? Int) ?? 0
        cacheCreate += (u["cache_creation_input_tokens"] as? Int) ?? 0
        cacheRead += (u["cache_read_input_tokens"] as? Int) ?? 0
    }

    mutating func ingestCodex(_ obj: [String: Any]) {
        guard let payload = obj["payload"] as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "session_meta":
            if cliVersion == nil, let v = payload["cli_version"] as? String { cliVersion = v }
            if let m = payload["model"] as? String, !m.isEmpty { note(m) }
        case "turn_context":
            if let m = payload["model"] as? String, !m.isEmpty { note(m) }
        case "event_msg":
            guard (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            // Cumulative for the session — the last one seen wins.
            codexInput = (total["input_tokens"] as? Int) ?? codexInput
            codexCached = (total["cached_input_tokens"] as? Int) ?? codexCached
            codexOutput = (total["output_tokens"] as? Int) ?? codexOutput
            codexTotal = (total["total_tokens"] as? Int) ?? codexTotal
            if let cw = info["model_context_window"] as? Int { contextWindow = cw }
        default:
            break
        }
    }

    private mutating func note(_ model: String) {
        if modelTurns[model] == nil { modelOrder.append(model) }
        modelTurns[model, default: 0] += 1
    }

    func finish(source: SessionSource) -> SessionInsights {
        var out = SessionInsights()
        out.models = modelOrder.sorted {
            let a = modelTurns[$0] ?? 0, b = modelTurns[$1] ?? 0
            if a != b { return a > b }
            return (modelOrder.firstIndex(of: $0) ?? 0) < (modelOrder.firstIndex(of: $1) ?? 0)
        }
        out.cliVersion = cliVersion
        out.contextWindow = contextWindow
        out.assistantTurns = turns
        switch source {
        case .claude:
            out.inputTokens = input
            out.cacheTokens = cacheRead + cacheCreate
            out.outputTokens = output
            out.totalTokens = input + cacheRead + cacheCreate + output
        case .codex:
            // Codex's `input_tokens` already includes the cached portion; split it
            // out so input + cache + output stays additive like the Claude path.
            out.cacheTokens = codexCached
            out.inputTokens = max(0, codexInput - codexCached)
            out.outputTokens = codexOutput
            out.totalTokens = codexTotal ?? (codexInput + codexOutput)
        }
        return out
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

/// Sidecar timestamps are ISO-8601, but may carry sub-millisecond fractions
/// (e.g. "2026-06-22T00:01:43.309337-05:00") that the strict ISO parser rejects.
/// Strip the fraction and retry so the offset still parses.
private func parseMentesTs(_ s: String?) -> Date {
    guard let s, !s.isEmpty else { return .distantPast }
    if let d = parseISO(s) { return d }
    let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return isoFormatterNoFraction.date(from: stripped) ?? .distantPast
}
