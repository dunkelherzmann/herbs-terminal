import SwiftUI

/// ssh runs this executable as its password helper and Tailcat proxy; those modes exit before any UI.
@main
enum AppMain {
    static func main() {
        if let status = HelperMode.run() { exit(status) }
        // Writing to an ssh that has gone away must fail with EPIPE, not end the app and every shell in it.
        signal(SIGPIPE, SIG_IGN)
        RenameMigration.run()
        RenameMigration.moveLoginDatabase()
        HerbsTerminalApp.main()
    }
}

/// The app was called HerbsTerminal. Its settings and saved data move over once, before anything reads them.
enum RenameMigration {
    static let oldDomain = "org.herbsterminal.app"
    static let doneKey = "migratedFromHerbsTerminal"

    /// Where the app keeps its own files, for every store that needs one.
    static func supportFolder(_ support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        support.appendingPathComponent("HerbsTerminal", isDirectory: true)
    }

    static func loginDatabase(_ support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        supportFolder(support).appendingPathComponent("logins.sqlite3")
    }

    /// Builds after the rename kept logins in "Herb's Terminal/" while everything else, including the
    /// migrated HerbsTerminal data, went to "HerbsTerminal/". The newer database moves in; a copy already there
    /// is set aside, never deleted. Retried at each launch until nothing is left behind.
    static func moveLoginDatabase(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        let fileManager = FileManager.default
        let strayFolder = support.appendingPathComponent("Herb's Terminal", isDirectory: true)
        let stray = strayFolder.appendingPathComponent("logins.sqlite3"), target = loginDatabase(support)
        guard fileManager.fileExists(atPath: stray.path) else { return }
        do {
            try fileManager.createDirectory(at: supportFolder(support), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                let aside = supportFolder(support).appendingPathComponent("logins-before-\(Int(Date().timeIntervalSince1970)).sqlite3")
                try fileManager.moveItem(at: target, to: aside)
            }
            try fileManager.moveItem(at: stray, to: target)
            if (try? fileManager.contentsOfDirectory(atPath: strayFolder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: strayFolder)
            }
        } catch {
            NSLog("Herb's Terminal: couldn't move the login database: \(error.localizedDescription)")
        }
    }

    static func run(defaults: UserDefaults = .standard,
                    oldSettings: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldDomain),
                    support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for (key, value) in oldSettings ?? [:] where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        let fileManager = FileManager.default
        let oldFolder = support.appendingPathComponent("HerbsTerminal"), newFolder = supportFolder(support)
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
