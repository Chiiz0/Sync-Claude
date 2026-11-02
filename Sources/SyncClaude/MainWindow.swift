import AppKit
import SwiftUI

enum MainWindow {
    static let id = "main"

    @MainActor static func open(using openWindow: OpenWindowAction) {
        // A Window scene reuses the existing window or recreates it after close.
        // NSApp.windows also contains menu/status windows, so never select by order.
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (@MainActor @Sendable () -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let reopenMainWindow else { return true }
        // MenuBarExtra can count as a visible window even when the main one is gone.
        // Defer until the current reopen event has finished being dispatched.
        DispatchQueue.main.async(execute: reopenMainWindow)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MainWindowContent<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().onAppear {
            // Keep the scene action available to Dock/Finder after the view closes.
            // Capture only the action, not the view or its data models.
            appDelegate.reopenMainWindow = { [openWindow] in MainWindow.open(using: openWindow) }
        }
    }
}

struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Sync Claude") { MainWindow.open(using: openWindow) }
    }
}

struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updates: UpdateModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                MainWindow.open(using: openWindow)
                updates.check(manual: true)
            }.disabled(updates.checking)
        }
        CommandGroup(replacing: .newItem) {
            OpenMainWindowButton().keyboardShortcut("0")
        }
    }
}
