import SwiftUI

/// ssh runs this executable as its password helper and Tailcat proxy; those modes exit before any UI.
@main
enum AppMain {
    static func main() {
        if let status = HelperMode.run() { exit(status) }
        RenameMigration.run()
        HerbsTerminalApp.main()
    }
}

/// The app was called HerbsTerminal. Its settings and saved data move over once, before anything reads them.
enum RenameMigration {
    static let oldDomain = "org.herbsterminal.app"
    static let doneKey = "migratedFromHerbsTerminal"

    static func run(defaults: UserDefaults = .standard,
                    oldSettings: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldDomain),
                    support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for (key, value) in oldSettings ?? [:] where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        let fileManager = FileManager.default
        let oldFolder = support.appendingPathComponent("HerbsTerminal"), newFolder = support.appendingPathComponent("HerbsTerminal")
        if fileManager.fileExists(atPath: oldFolder.path), !fileManager.fileExists(atPath: newFolder.path) {
            try? fileManager.moveItem(at: oldFolder, to: newFolder)
        }
        // The old cache only held sockets and one-shot launchers; nothing there is worth keeping.
        try? fileManager.removeItem(at: caches.appendingPathComponent("HerbsTerminal"))
        defaults.set(true, forKey: doneKey)
    }
}

struct HerbsTerminalApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var delegate
    @ObservedObject private var profile = TerminalProfile.shared
    var body: some Scene {
        WindowGroup("Herb's Terminal", id: "session") { WorkspaceView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: profile.windowWidth, height: profile.windowHeight)
            .commands { TerminalCommands() }
        Settings { SettingsView() }
    }
}

final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Herb's Terminal has its own tab strip; macOS window tabs would add a second, conflicting set.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ask once for every window before quitting, as Terminal does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard Workspace.confirmClosing(Workspace.all.flatMap(\.tabs), scope: "Herb's Terminal") else { return .terminateCancel }
            SessionRestore.save(Workspace.all)
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { TailcatShare.shared.stop() }
    }
}
