import Foundation

// MARK: - View-model rows

/// A point on the activity trend (daily or weekly bucket).
struct TrendPoint: Identifiable {
    let id: String      // the raw period string
    let date: Date
    let label: String   // short axis label
    let tokens: Int
    let cost: Double
}

/// Tokens attributed to one project — recall's contribution that ccusage can't
/// produce on its own (ccusage knows sessions, recall knows their project).
struct ProjectUsage: Identifiable {
    let id: String      // project path ("" → no project)
    let name: String
    let tokens: Int
    let cost: Double
    let sessions: Int
}

struct AgentUsage: Identifiable {
    let id: String      // "claude" | "codex" | …
    let tokens: Int
    let cost: Double
    var name: String { id.prefix(1).uppercased() + id.dropFirst() }
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    @Published var loading = false
    @Published var error: String?
    @Published var loaded = false

    @Published var totals: CCTotals?
    @Published var today: CCPeriodUsage?
    @Published var monthTokens = 0
    @Published var monthCost = 0.0
    @Published var dailyPoints: [TrendPoint] = []
    @Published var weeklyPoints: [TrendPoint] = []
    @Published var projects: [ProjectUsage] = []
    @Published var agents: [AgentUsage] = []
    @Published var unmatchedTokens = 0   // session tokens we couldn't map to a project

    private let cc = CCUsageCLI()
    var available: Bool { cc.isAvailable }

    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Pull all three reports in parallel, then join session usage to recall's
    /// project map. `sessions` is the app's already-loaded recall session list.
    func load(sessions: [SessionMeta], force: Bool = false) async {
        guard available else { error = CCUsageError.notFound.errorDescription; return }
        guard !loading, force || !loaded else { return }
        loading = true
        error = nil
        do {
            async let d = cc.daily()
            async let w = cc.weekly()
            async let s = cc.sessions()
            let (daily, weekly, session) = try await (d, w, s)

            totals = daily.totals
            dailyPoints = Self.points(daily.daily, weekly: false).suffix(30).map { $0 }
            weeklyPoints = Self.points(weekly.weekly, weekly: true).suffix(16).map { $0 }

            let todayKey = Self.ymd.string(from: Date())
            today = daily.daily.first { $0.period == todayKey }
            let monthPrefix = String(todayKey.prefix(7))   // "2026-06"
            let monthRows = daily.daily.filter { $0.period.hasPrefix(monthPrefix) }
            monthTokens = monthRows.reduce(0) { $0 + $1.totalTokens }
            monthCost = monthRows.reduce(0) { $0 + $1.totalCost }

            joinProjects(session.session, sessions: sessions)
            joinAgents(session.session)
            loaded = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    // MARK: Joins

    private func joinProjects(_ rows: [CCSessionUsage], sessions: [SessionMeta]) {
        // session UUID → project path (recall is the source of truth for project).
        var projectByID: [String: String] = [:]
        for s in sessions { projectByID[s.sessionID] = s.project }

        var tok: [String: Int] = [:]
        var cost: [String: Double] = [:]
        var count: [String: Int] = [:]
        var unmatched = 0
        for r in rows {
            guard let path = projectByID[sessionUUID(from: r.period)] else {
                unmatched += r.totalTokens
                continue
            }
            tok[path, default: 0] += r.totalTokens
            cost[path, default: 0] += r.totalCost
            count[path, default: 0] += 1
        }
        projects = tok.keys.map { path in
            ProjectUsage(id: path,
                         name: path.isEmpty ? "(no project)" : (path as NSString).lastPathComponent,
                         tokens: tok[path] ?? 0,
                         cost: cost[path] ?? 0,
                         sessions: count[path] ?? 0)
        }
        .sorted { $0.tokens > $1.tokens }
        unmatchedTokens = unmatched
    }

    private func joinAgents(_ rows: [CCSessionUsage]) {
        var tok: [String: Int] = [:]
        var cost: [String: Double] = [:]
        for r in rows {
            let a = r.agent ?? "other"
            tok[a, default: 0] += r.totalTokens
            cost[a, default: 0] += r.totalCost
        }
        agents = tok.keys.map { AgentUsage(id: $0, tokens: tok[$0] ?? 0, cost: cost[$0] ?? 0) }
            .sorted { $0.tokens > $1.tokens }
    }

    private static func points(_ rows: [CCPeriodUsage], weekly: Bool) -> [TrendPoint] {
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = weekly ? "MMM d" : "MMM d"
        return rows.compactMap { r in
            guard let date = ymd.date(from: r.period) else { return nil }
            return TrendPoint(id: r.period, date: date, label: out.string(from: date),
                              tokens: r.totalTokens, cost: r.totalCost)
        }
    }
}

// MARK: - Formatting helpers

enum UsageFormat {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 1_000_000...:     return String(format: "%.1fM", d / 1e6)
        case 1_000...:         return String(format: "%.1fK", d / 1e3)
        default:               return "\(n)"
        }
    }

    static func cost(_ c: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = c >= 100 ? 0 : 2
        return f.string(from: NSNumber(value: c)) ?? String(format: "$%.2f", c)
    }
}
