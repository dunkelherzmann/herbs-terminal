import CGtk
import CHerb
import Foundation
import Glibc

/// ssh runs this executable as its password helper and Tailcat proxy; those modes exit before any UI.
@main
enum AppMain {
    static func main() {
        if let status = HelperMode.run() { exit(status) }
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
        #endif
        // Writing to an ssh that has gone away must fail with EPIPE, not end the app and every shell in it.
        signal(SIGPIPE, SIG_IGN)
        exit(MainActor.assumeIsolated { App.shared.run() })
    }
}

/// The application: windows, app-wide actions and shortcuts, and what happens at launch and quit.
@MainActor
final class App {
    static let shared = App()
    private(set) var application: OpaquePointer?
    /// Objects kept alive while their window is open.
    private var retained: [ObjectIdentifier: AnyObject] = [:]
    private var observers: [ObservationToken] = []
    private var pendingWindows: [SavedWindow] = []
    private var quitting = false

    func retain(_ object: AnyObject) { retained[ObjectIdentifier(object)] = object }
    func release(_ object: AnyObject) { retained[ObjectIdentifier(object)] = nil }

    func run() -> Int32 {
        let app = adw_application_new(Host.appID, G_APPLICATION_DEFAULT_FLAGS)!
        application = c(app)
        on(app, "startup") { [weak self] _ in self?.startup() }
        on(app, "activate") { [weak self] _ in self?.activate() }
        on(app, "shutdown") { _ in
            TailcatShare.shared.stop()
        }
        g_set_application_name("Herb's Terminal")
        herb_integrate_dispatch()
        return g_application_run(c(app), 0, nil)
    }

    private func startup() {
        Styles.install()
        Appearance.apply(TerminalProfile.shared.appearance)
        observers.append(TerminalProfile.shared.objectWillChange.observe { Appearance.apply(TerminalProfile.shared.appearance) })
        on(adw_style_manager_get_default(), "notify::dark") { _ in
            Workspace.all.forEach { $0.allPanes.forEach { $0.applyColors() } }
        }
        installActions()
        pendingWindows = TerminalProfile.shared.restoreSession ? SavedSession.read().filter { !$0.tabs.isEmpty } : []
    }

    private var activated = false

    /// The first launch reopens the last session's windows; later activations (the launcher clicked again) open a
    /// new window.
    private func activate() {
        if !activated, !pendingWindows.isEmpty {
            activated = true
            let windows = pendingWindows
            pendingWindows = []
            windows.forEach { Workspace(restoring: $0).present() }
            return
        }
        activated = true
        Workspace().present()
    }

    func newWindow() { Workspace().present() }

    // MARK: App actions

    private func installActions() {
        let map = application
        addAction(map, "new-window") { [weak self] in self?.newWindow() }
        addAction(map, "settings") { SettingsWindow.show() }
        addAction(map, "about") { AboutDialog.show() }
        addAction(map, "quit") { [weak self] in self?.quit() }
        let accels: [(String, [String])] = [
            ("app.new-window", ["<Control><Shift>n"]), ("app.settings", ["<Control>comma"]), ("app.quit", ["<Control><Shift>q"]),
        ] + Workspace.accelerators
        for (action, keys) in accels {
            var pointers = keys.map { UnsafePointer(strdup($0)) } + [nil]
            gtk_application_set_accels_for_action(c(application), action, &pointers)
            pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        }
    }

    /// Asks once for every window before quitting, as Terminal does, and saves the session.
    func quit() {
        guard !quitting else { return }
        Task {
            guard await Workspace.confirmClosing(Workspace.all.flatMap(\.tabs), scope: "Herb's Terminal", parent: nil) else { return }
            quitting = true
            Workspace.saveSession()
            Workspace.all.forEach { $0.closeWithoutAsking() }
            g_application_quit(c(application))
        }
    }

    var isQuitting: Bool { quitting }
}

/// About Herb's Terminal: the name, the version, what it is, the author and a link to the project.
@MainActor
enum AboutDialog {
    static let projectURL = "https://github.com/dunkelherzmann/herbs-terminal"

    static func show() {
        let about = adw_about_dialog_new()!
        let dialog: OpaquePointer = c(about)
        adw_about_dialog_set_application_name(dialog, "Herb's Terminal")
        adw_about_dialog_set_application_icon(dialog, "org.herbsterminal.app")
        adw_about_dialog_set_version(dialog, appVersion)
        adw_about_dialog_set_comments(dialog, "A terminal for administrators.")
        adw_about_dialog_set_developer_name(dialog, "By dunkelherzmann")
        adw_about_dialog_set_website(dialog, projectURL)
        adw_about_dialog_set_issue_url(dialog, projectURL + "/issues")
        adw_about_dialog_set_copyright(dialog, "© Herbert Cisneros")
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        adw_about_dialog_add_legal_section(dialog, "tailcat", "© Tailscale Inc & contributors", GTK_LICENSE_BSD_3, nil)
        adw_about_dialog_add_legal_section(dialog, "VTE", "© the VTE authors", GTK_LICENSE_LGPL_3_0, nil)
        adw_dialog_present(c(about), Dialogs.anchor(nil))
    }
}
