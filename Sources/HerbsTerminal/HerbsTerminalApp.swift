import SwiftUI

@main
struct HerbsTerminalApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("HerbsTerminal", id: "session") { WorkspaceView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 960, height: 580)
    }
}

final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
