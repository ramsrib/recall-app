import SwiftUI
import AppKit

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Recall") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reindex Sessions") { state.reindex() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// Ensures the process behaves as a regular foreground app even when launched
/// unbundled via `swift run` (a packaged .app already gets this for free).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
