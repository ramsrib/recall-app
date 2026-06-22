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

// MARK: - Mentes task (read from the `<id>.mentes.jsonl` sidecar)

/// One Mentes task a session touched, derived in-app from the session's
/// `<id>.mentes.jsonl` sidecar (read on open by SessionStore — see there).
struct MentesTask: Identifiable, Hashable {
    let taskID: String
    let action: String   // latest action seen ("create" | "update" | …)
    let date: Date       // latest event time
    let events: Int      // how many times the task was touched
    let mentesURL: String

    var id: String { taskID }
    var shortID: String { String(taskID.prefix(8)) }
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

    /// Bucket sessions by recency (pinned float into their own group). Input is
    /// expected newest-first (as `recall list` returns it); order is preserved.
    static func build(from sessions: [SessionMeta]) -> [SessionGroup] {
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
}
