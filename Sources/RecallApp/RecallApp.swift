import SwiftUI
import AppKit

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 640)
                // Deep link: `recall://session/<id>` selects that thread.
                .onOpenURL { state.handleDeepLink($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reindex Sessions") { state.reindex() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Sessions") { state.searchFocusRequested = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(state.sidebarItem == .usage ? "Show Sessions" : "Show Usage") {
                    state.sidebarItem = state.sidebarItem == .usage ? state.lastRealFilter : .usage
                }
                .keyboardShortcut("u", modifiers: .command)
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
