import Foundation

enum RecallError: LocalizedError {
    case notFound
    case cli(String)
    case exit(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The `recall` CLI was not found. Install it (run `make install` in the recall repo) so it lands in ~/.local/bin."
        case .cli(let msg): return msg
        case .exit(let code): return "recall exited with status \(code)."
        case .decode(let msg): return "Couldn't read recall's output: \(msg)"
        }
    }
}

/// Drives the installed `recall` binary. The app is a thin client over the CLI —
/// list / summary / pin / resume all come straight from it, so the GUI and the
/// terminal never disagree.
struct RecallCLI {
    let binaryPath: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/recall",
            "/opt/homebrew/bin/recall",
            "/usr/local/bin/recall",
        ]
        binaryPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { binaryPath != nil }

    // MARK: Commands

    func list() async throws -> [SessionMeta] {
        // Ask for every mode (interactive + exec); the app hides exec by default
        // and reveals it via the Automation filter, so it needs the full set.
        let data = try await run(["list", "--mode", "all"])
        return try decode([SessionMeta].self, data)
    }

    /// Generate (or fetch cached) summary. First generation shells out to codex
    /// and can take several seconds; cached calls return immediately.
    func summary(_ sessionID: String, refresh: Bool = false,
                 cachedOnly: Bool = false) async throws -> SummaryResult {
        var args = ["summary", sessionID]
        if refresh { args.append("--refresh") }
        if cachedOnly { args.append("--cached-only") }   // never generates; empty if no cache
        let data = try await run(args)
        return try decode(SummaryResult.self, data)
    }

    func setPinned(_ sessionID: String, _ pinned: Bool) async throws {
        _ = try await run([pinned ? "pin" : "unpin", sessionID])
    }

    func resume(_ sessionID: String) async throws -> ResumeInfo {
        let data = try await run(["resume", sessionID])
        return try decode(ResumeInfo.self, data)
    }

    func index(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let bin = binaryPath else { throw RecallError.notFound }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["index"]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            let buffer = LineBuffer(onLine: progress)
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { buffer.append(d) }
            }
            proc.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffer.flush()
                p.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: RecallError.exit(Int(p.terminationStatus)))
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Plumbing

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RecallError.decode(error.localizedDescription) }
    }

    private func run(_ args: [String]) async throws -> Data {
        guard let bin = binaryPath else { throw RecallError.notFound }
        let result = try await capture(bin, args)
        if result.code != 0 {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecallError.cli(msg.isEmpty ? "recall exited with status \(result.code)" : msg)
        }
        return result.stdout
    }

    private func capture(_ bin: String, _ args: [String]) async throws
        -> (stdout: Data, stderr: String, code: Int32) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let sink = DataSink()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if !d.isEmpty { sink.appendOut(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; if !d.isEmpty { sink.appendErr(d) }
            }
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let leftoverOut = outPipe.fileHandleForReading.availableData
                let leftoverErr = errPipe.fileHandleForReading.availableData
                if !leftoverOut.isEmpty { sink.appendOut(leftoverOut) }
                if !leftoverErr.isEmpty { sink.appendErr(leftoverErr) }
                let (o, e) = sink.snapshot()
                cont.resume(returning: (o, String(decoding: e, as: UTF8.self), p.terminationStatus))
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}

private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private let onLine: @Sendable (String) -> Void
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); buf.append(data)
        var lines: [String] = []
        while let nl = buf.firstIndex(of: 0x0a) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if let s = String(data: line, encoding: .utf8) { lines.append(s) }
        }
        lock.unlock()
        for l in lines where !l.isEmpty { onLine(l) }
    }

    func flush() {
        lock.lock(); let rest = buf; buf.removeAll(); lock.unlock()
        if let s = String(data: rest, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onLine(s) }
    }
}
