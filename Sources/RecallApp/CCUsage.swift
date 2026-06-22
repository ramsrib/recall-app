import Foundation

// MARK: - ccusage JSON models
//
// Decoded from `ccusage <report> --json`. ccusage reports token + cost usage for
// every detected coding-agent CLI (Claude Code, Codex, …). We only decode the
// fields we render; ccusage emits more (modelBreakdowns, metadata, …).

/// One time-bucket row from `daily` / `weekly` / `monthly`.
struct CCPeriodUsage: Decodable {
    let period: String            // "2026-06-19" (daily) | week-start date | "2026-06" (monthly)
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double
}

/// One session row from `session`. `period` is the Claude session UUID, or a
/// Codex rollout path that *embeds* the session UUID (extracted by `sessionUUID`).
struct CCSessionUsage: Decodable {
    let period: String
    let agent: String?
    let totalTokens: Int
    let totalCost: Double
}

struct CCTotals: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double
}

struct CCDailyReport: Decodable { let daily: [CCPeriodUsage]; let totals: CCTotals }
struct CCWeeklyReport: Decodable { let weekly: [CCPeriodUsage]; let totals: CCTotals }
struct CCSessionReport: Decodable { let session: [CCSessionUsage]; let totals: CCTotals }

/// Pulls the session UUID out of a ccusage `period`. Claude periods already ARE
/// the UUID; Codex periods look like `2026/06/21/rollout-…-<uuid>` — we want the
/// trailing UUID so it lines up with recall's `session_id`.
func sessionUUID(from period: String) -> String {
    let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    if let r = period.range(of: pattern, options: .regularExpression) {
        return String(period[r])
    }
    return period
}

// MARK: - CLI driver

enum CCUsageError: LocalizedError {
    case notFound
    case exit(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The `ccusage` CLI wasn't found. Install it (`brew install ccusage` or `npm i -g ccusage`) so usage data can load."
        case .exit(let code, let msg):
            return msg.isEmpty ? "ccusage exited with status \(code)." : msg
        case .decode(let msg):
            return "Couldn't read ccusage's output: \(msg)"
        }
    }
}

/// Thin wrapper over the installed `ccusage` binary (JSON mode). Mirrors RecallCLI
/// — the app stays a thin client over CLIs that already emit clean JSON.
struct CCUsageCLI {
    let binaryPath: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ccusage",
            "\(home)/.local/bin/ccusage",
            "/usr/local/bin/ccusage",
            "\(home)/.bun/bin/ccusage",
        ]
        binaryPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { binaryPath != nil }

    // `--offline` uses ccusage's bundled/cached pricing instead of fetching it
    // over the network — that fetch is the ENTIRE latency (~0.47s → ~0.05s per
    // call). Cost figures stay accurate enough for a usage glance.
    func daily() async throws -> CCDailyReport {
        try decode(CCDailyReport.self, await run(["daily", "--json", "--offline"]))
    }
    func weekly() async throws -> CCWeeklyReport {
        try decode(CCWeeklyReport.self, await run(["weekly", "--json", "--offline"]))
    }
    func sessions() async throws -> CCSessionReport {
        try decode(CCSessionReport.self, await run(["session", "--json", "--offline"]))
    }

    // MARK: Plumbing

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CCUsageError.decode(error.localizedDescription) }
    }

    private func run(_ args: [String]) async throws -> Data {
        guard let bin = binaryPath else { throw CCUsageError.notFound }
        let r = try await capture(bin, args)
        if r.code != 0 {
            throw CCUsageError.exit(Int(r.code), r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }

    private func capture(_ bin: String, _ args: [String]) async throws
        -> (stdout: Data, stderr: String, code: Int32) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            // ccusage is a Node CLI; give it a sane PATH for any node lookup.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
            proc.environment = env
            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let sink = CCDataSink()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if !d.isEmpty { sink.appendOut(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if !d.isEmpty { sink.appendErr(d) }
            }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let lo = outPipe.fileHandleForReading.availableData
                let le = errPipe.fileHandleForReading.availableData
                if !lo.isEmpty { sink.appendOut(lo) }
                if !le.isEmpty { sink.appendErr(le) }
                let (o, e) = sink.snapshot()
                cont.resume(returning: (o, String(decoding: e, as: UTF8.self), p.terminationStatus))
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}

private final class CCDataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}
