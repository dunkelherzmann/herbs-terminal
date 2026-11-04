import SwiftUI

@main
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
