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
        case .cli(let msg):
            return msg
        case .exit(let code):
            return "recall exited with status \(code)."
        case .decode(let msg):
            return "Couldn't read recall's output: \(msg)"
        }
    }
}

/// Thin wrapper that drives the installed `recall` binary as a sidecar.
/// All search semantics (hybrid/semantic/lexical/all) come straight from the
/// CLI, so the app and the CLI can never disagree on what a search means.
struct RecallCLI {

    /// Absolute path to the recall binary. A .app launched from Finder gets a
    /// minimal PATH (no ~/.local/bin), so we resolve an absolute path here.
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

    // MARK: Search

    func search(query: String, mode: SearchMode, source: String?,
                project: String?, limit: Int) async throws -> [SearchResult] {
        guard let bin = binaryPath else { throw RecallError.notFound }

        var args: [String] = [query]
        switch mode {
        case .all:
            args.append("--all")
        default:
            args += ["--mode", mode.rawValue]
        }
        if let source { args += ["--source", source] }
        if let project, !project.isEmpty { args += ["--project", project] }
        args += ["--limit", String(limit)]

        let result = try await capture(bin, args)
        if result.code != 0 {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecallError.cli(msg.isEmpty ? "recall exited with status \(result.code)" : msg)
        }
        guard !result.stdout.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([SearchResult].self, from: result.stdout)
        } catch {
            throw RecallError.decode(error.localizedDescription)
        }
    }

    // MARK: Index (streams progress lines from stderr)

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
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { buffer.append(data) }
            }
            proc.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                buffer.flush()
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: RecallError.exit(Int(p.terminationStatus)))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Process plumbing

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

            // Buffer both streams via handlers so a full pipe never deadlocks.
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

/// Thread-safe accumulator for the two process streams.
private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

/// Splits a byte stream into newline-delimited lines and forwards each.
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
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLine(s)
        }
    }
}
