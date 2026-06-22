import Foundation
import AppKit

/// Resumes a session in Tarp using its LOCAL launch-configuration mechanism
/// (verified to actually RUN the command, unlike `new_tab?path=` which only opens
/// a tab in the dir):
///   1. Write ~/.tarp/launch_configurations/recall-resume.yaml — a tab in the
///      project dir whose `commands:` run on open.
///   2. Open `tarp://launch/recall-resume`.
///   3. Copy the command to the clipboard as a fallback.
struct TarpLauncher {
    private let tarpAppPath = "/Applications/Tarp.app"
    private let configName = "recall-resume"

    var isAvailable: Bool { FileManager.default.fileExists(atPath: tarpAppPath) }

    @discardableResult
    func launch(_ info: ResumeInfo) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(info.command, forType: .string)

        guard isAvailable else {
            return "Tarp not found. Resume command copied to clipboard: \(info.command)"
        }

        writeLaunchConfig(info)
        if let url = URL(string: "tarp://launch/\(configName)") {
            NSWorkspace.shared.open(url)
        }

        let dir = (info.cwd as NSString).lastPathComponent
        return "Resuming in Tarp: \(info.command) — in \(dir.isEmpty ? info.cwd : dir)"
    }

    private func writeLaunchConfig(_ info: ResumeInfo) {
        let dir = NSString(string: "~/.tarp/launch_configurations").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let yaml = """
        ---
        name: \(configName)
        windows:
          - tabs:
              - layout:
                  cwd: \(yamlString(info.cwd))
                  is_focused: true
                  commands:
                    - exec: \(yamlString(info.command))
        """
        let file = (dir as NSString).appendingPathComponent("\(configName).yaml")
        try? yaml.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// YAML double-quoted scalar (escape backslash and double-quote).
    private func yamlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
