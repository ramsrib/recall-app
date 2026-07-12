import Foundation

// MARK: - Source (a quiet badge, never a navigation axis)

enum SessionSource: String, Hashable, Codable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

// MARK: - Session list row (decoded from `recall list`)

struct SessionMeta: Decodable, Identifiable, Hashable {
    let source: String
    let sessionID: String
    let project: String
    let title: String
    let firstTs: Int64
    let lastTs: Int64
    let msgCount: Int
    let path: String
    let pinned: Bool
    let hasSummary: Bool
    let archived: Bool
    let mode: String?       // "interactive" | "exec" (nil from older CLI builds)

    enum CodingKeys: String, CodingKey {
        case source, project, title, path, pinned, archived, mode
        case sessionID = "session_id"
        case firstTs = "first_ts"
        case lastTs = "last_ts"
        case msgCount = "msg_count"
        case hasSummary = "has_summary"
    }

    var id: String { sessionID }
    var sourceKind: SessionSource { SessionSource(rawValue: source) ?? .claude }
    /// Non-interactive, programmatic run (`codex exec` / `claude -p`). Hidden by
    /// default; surfaced only under the Automation filter.
    var isExec: Bool { mode == "exec" }
    var lastDate: Date { Date(timeIntervalSince1970: TimeInterval(lastTs)) }
    var displayTitle: String { title.isEmpty ? "(untitled)" : title }
    var projectName: String {
        let base = (project as NSString).lastPathComponent
        return base.isEmpty ? project : base
    }
}

// MARK: - Summary (decoded from `recall summary`)

struct SummaryResult: Decodable {
    let source: String
    let sessionID: String
    let cached: Bool
    let summary: String

    enum CodingKeys: String, CodingKey {
        case source, cached, summary
        case sessionID = "session_id"
    }
}

// MARK: - Task (read from the optional `.mentes.jsonl` sidecar)

/// One task a session touched, derived in-app from the optional `.mentes.jsonl`
/// sidecar next to the transcript (read on open by SessionStore — see there).
/// Absent for every session that has no sidecar, which is the normal case.
struct MentesTask: Identifiable, Hashable {
    let taskID: String
    let action: String   // latest action seen ("create" | "update" | …)
    let date: Date       // latest event time
    let events: Int      // how many times the task was touched
    let mentesURL: String

    var id: String { taskID }
    var shortID: String { String(taskID.prefix(8)) }
}

// MARK: - Park marker (read from the optional `.park.json` sidecar)

/// A session parked as a resumable task, decoded from the optional `.park.json`
/// marker written next to the transcript. Distinct from the `.mentes.jsonl` log
/// (which records *every* task a session touched): the marker names the ONE park
/// task and carries its live title/status, so it's the right source for "is this
/// session parked?". Absent unless something wrote one.
struct ParkMarker: Decodable, Equatable {
    let taskID: String?
    let title: String?
    let status: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, status
        case taskID = "task_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// An aborted park leaves an empty `{}` marker — only count it as parked once
    /// it actually names a task.
    var isParked: Bool { !(taskID ?? "").isEmpty }

    /// "IN_PROGRESS" → "In Progress".
    var statusDisplay: String? {
        guard let s = status, !s.isEmpty else { return nil }
        return s.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

// MARK: - Resume (decoded from `recall resume`)

struct ResumeInfo: Decodable {
    let source: String
    let sessionID: String
    let cwd: String
    let command: String
    let path: String

    enum CodingKeys: String, CodingKey {
        case source, cwd, command, path
        case sessionID = "session_id"
    }
}

// MARK: - Sidebar filters

enum SidebarItem: Hashable {
    case all
    case pinned
    case parked            // sessions with a `.park.json` marker (resumable Mentes tasks)
    case archived
    case automation        // non-interactive exec runs (hidden everywhere else)
    case usage             // ccusage dashboard (shown in the detail column)
    case tool(SessionSource)
    case project(String)   // full project path
}

struct ProjectFacet: Identifiable, Hashable {
    let path: String
    let count: Int
    let lastTs: Int64
    var id: String { path }
    var name: String {
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }
}

// MARK: - Time grouping for the list

enum TimeBucket: String, CaseIterable, Identifiable {
    case pinned = "Pinned"
    case parked = "Parked"
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "This Week"
    case older = "Older"
    var id: String { rawValue }
}

struct SessionGroup: Identifiable {
    let bucket: TimeBucket
    let sessions: [SessionMeta]
    var id: String { bucket.rawValue }

    /// Bucket sessions by recency. Pinned and parked sessions float into their own
    /// groups at the top (pinned first, then parked) so they're always visible
    /// regardless of the active filter — a session that is both counts as pinned.
    /// Input is expected newest-first (as `recall list` returns it); order is kept.
    static func build(from sessions: [SessionMeta], parkedIDs: Set<String> = []) -> [SessionGroup] {
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) ?? startToday
        let startWeek = cal.date(byAdding: .day, value: -7, to: startToday) ?? startToday

        var buckets: [TimeBucket: [SessionMeta]] = [:]
        for s in sessions {
            if s.pinned {
                buckets[.pinned, default: []].append(s)
                continue
            }
            if parkedIDs.contains(s.sessionID) {
                buckets[.parked, default: []].append(s)
                continue
            }
            let d = s.lastDate
            let b: TimeBucket
            if d >= startToday { b = .today }
            else if d >= startYesterday { b = .yesterday }
            else if d >= startWeek { b = .week }
            else { b = .older }
            buckets[b, default: []].append(s)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let arr = buckets[bucket], !arr.isEmpty else { return nil }
            return SessionGroup(bucket: bucket, sessions: arr)
        }
    }
}

// MARK: - Parsed transcript (for the reader)

struct TranscriptMessage: Identifiable, Hashable {
    let id = UUID()
    let role: Role
    let blocks: [Block]
    let timestamp: Date?

    enum Role: String {
        case user, assistant, system, tool
        func displayName(for source: SessionSource) -> String {
            switch self {
            case .user:      return "You"
            case .assistant: return source.displayName
            case .system:    return "System"
            case .tool:      return "Tool"
            }
        }
    }

    enum Block: Hashable {
        case text(String)
        case thinking(String)
        case toolUse(name: String, input: String)
        case toolResult(String)
    }
}

struct ParsedTranscript {
    var title: String
    var messages: [TranscriptMessage]
    var insights = SessionInsights()
}

// MARK: - Session insights (model + token usage, derived from the transcript)

/// Model + token totals for the selected session, extracted in-app from the
/// transcript on open (see SessionStore.parseTranscript). Purely transcript-
/// derived — no `ccusage` dependency — so it's per-session accurate and works
/// offline. Token fields are normalized across sources so they stay additive:
/// `totalTokens == inputTokens + cacheTokens + outputTokens`.
struct SessionInsights: Equatable {
    var models: [String] = []       // distinct model ids, primary (most-used) first
    var inputTokens = 0             // non-cached prompt tokens
    var cacheTokens = 0             // cache read + creation (Claude) / cached input (Codex)
    var outputTokens = 0            // completion tokens (incl. reasoning)
    var totalTokens = 0
    var contextWindow: Int?         // model context window (Codex reports it)
    var cliVersion: String?         // Claude Code / Codex CLI version
    var assistantTurns = 0          // model responses seen

    var hasTokens: Bool { totalTokens > 0 }
    var isEmpty: Bool { models.isEmpty && totalTokens == 0 }

    /// Human model label(s): "Opus 4.8", or "Opus 4.8 · Haiku 4.5" when a session
    /// spanned models (e.g. a subagent or title model).
    var modelDisplay: String {
        let names = models.prefix(3).map(Self.prettyModel)
        return names.isEmpty ? "Unknown model" : names.joined(separator: " · ")
    }

    /// Prettify a raw model id for display: `claude-opus-4-8` → "Opus 4.8",
    /// `claude-haiku-4-5-20251001` → "Haiku 4.5", `gpt-5.2-codex` → "GPT-5.2 Codex".
    static func prettyModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("claude") {
            var s = raw
            s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression) // strip [1m]
            s = s.replacingOccurrences(of: #"-\d{6,}$"#, with: "", options: .regularExpression)   // strip date snapshot
            let families = ["opus", "sonnet", "haiku", "fable"]
            let parts = s.split(separator: "-").map(String.init)
            let family = parts.first { families.contains($0.lowercased()) }
            let version = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            if let family {
                let cap = family.prefix(1).uppercased() + family.dropFirst()
                return version.isEmpty ? cap : "\(cap) \(version)"
            }
            return raw
        }
        if lower.hasPrefix("gpt") || lower.contains("codex") {
            var s = raw
            if let r = s.range(of: "gpt", options: .caseInsensitive) { s.replaceSubrange(r, with: "GPT") }
            s = s.replacingOccurrences(of: "-codex", with: " Codex", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "codex", with: "Codex", options: .caseInsensitive)
            return s
        }
        return raw
    }
}
