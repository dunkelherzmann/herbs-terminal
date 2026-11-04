import SwiftUI

/// ssh runs this executable as its password helper and Tailcat proxy; those modes exit before any UI.
@main
enum HerbsTerminalMain {
    static func main() {
        if let status = HerbsTerminalHelper.run() { exit(status) }
        HerbsTerminalApp.main()
    }
}

struct HerbsTerminalApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var delegate
    @ObservedObject private var profile = TerminalProfile.shared
    var body: some Scene {
        WindowGroup("HerbsTerminal", id: "session") { WorkspaceView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: profile.windowWidth, height: profile.windowHeight)
            .commands { TerminalCommands() }
        Settings { SettingsView() }
    }
}

final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // HerbsTerminal has its own tab strip; macOS window tabs would add a second, conflicting set.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TailcatShare.shared.stop() }
    }
}
