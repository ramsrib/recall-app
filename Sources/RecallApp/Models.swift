import Foundation

// MARK: - Sources

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

enum SourceFilter: String, Hashable, CaseIterable {
    case all, claude, codex

    /// The `--source` value to pass to the recall CLI (nil = no filter).
    var cliValue: String? {
        switch self {
        case .all:    return nil
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }

    func matches(_ source: SessionSource) -> Bool {
        switch self {
        case .all:    return true
        case .claude: return source == .claude
        case .codex:  return source == .codex
        }
    }
}

enum SearchMode: String, Hashable, CaseIterable, Identifiable {
    case hybrid, semantic, lexical, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hybrid:   return "Hybrid"
        case .semantic: return "Semantic"
        case .lexical:  return "Lexical"
        case .all:      return "All-keywords"
        }
    }

    /// Whether this mode needs Ollama (embeddings) to be running.
    var needsOllama: Bool { self == .hybrid || self == .semantic }
}

// MARK: - Search results (decoded from `recall` JSON)

struct SearchResult: Decodable, Hashable {
    let source: String
    let sessionID: String
    let project: String
    let title: String
    let role: String
    let ts: Int64
    let path: String
    let score: Double
    let snippet: String

    enum CodingKeys: String, CodingKey {
        case source, project, title, role, ts, path, score, snippet
        case sessionID = "session_id"
    }

    var sourceKind: SessionSource { SessionSource(rawValue: source) ?? .claude }
    var date: Date? { ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil }
    var projectName: String {
        let base = (project as NSString).lastPathComponent
        return base.isEmpty ? project : base
    }
}

// MARK: - Browsed sessions (discovered on disk)

struct SessionRef: Identifiable, Hashable {
    let path: String
    let source: SessionSource
    let sessionID: String
    let project: String
    let title: String
    let modified: Date

    var id: String { path }
    var projectName: String {
        let base = (project as NSString).lastPathComponent
        return base.isEmpty ? project : base
    }
}

// MARK: - Parsed transcript

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
