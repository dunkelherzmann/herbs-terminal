import SwiftUI

/// ssh runs this executable as its password helper and Tailcat proxy; those modes exit before any UI.
@main
enum AppMain {
    static func main() {
        if let status = HelperMode.run() { exit(status) }
        // Writing to an ssh that has gone away must fail with EPIPE, not end the app and every shell in it.
        signal(SIGPIPE, SIG_IGN)
        HerbsTerminalApp.main()
    }
}

/// Herb's Terminal ▸ About: the name, the version (from the bundle), what it is, the author and a link to the project.
@MainActor
enum AboutPanel {
    static let projectURL = URL(string: "https://github.com/dunkelherzmann/herbs-terminal")!

    static func show() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
        let credits = NSMutableAttributedString(string: "A terminal for administrators.\n\nBy dunkelherzmann\n", attributes: base)
        var link = base
        link[.link] = projectURL
        credits.append(NSAttributedString(string: projectURL.absoluteString, attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Herb's Terminal", .credits: credits])
        NSApp.activate()
    }
}

/// Where the app keeps its own files, for every store that needs one.
enum AppFolders {
    static func support(_ base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        (ParityScene.isActive ? ParityScene.home : base).appendingPathComponent("HerbsTerminal", isDirectory: true)
    }

    static func loginDatabase(_ base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        support(base).appendingPathComponent("logins.sqlite3")
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
        // A parity check runs while the user works: its window opens without taking focus.
        if !ParityScene.isActive { NSApp.activate(ignoringOtherApps: true) }
        // A parity copy never uses the user's clipboard.
        if ParityScene.isActive { PrivatePasteboard.install() }
        TestDesktop.start()
        TestBridge.start()
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
