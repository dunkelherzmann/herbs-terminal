import SwiftUI
import SwiftTerm

@MainActor
final class LocalShell: ObservableObject, Identifiable {
    let id = UUID()
    let view = HerbsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                 font: TerminalProfile.shared.defaultProfile.settings.font,
                                 options: TerminalOptions(scrollback: TerminalProfile.shared.defaultProfile.settings.scrollbackLines))
    /// Where the login shell starts; new tabs pass the current tab's folder or their profile's.
    var startDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    /// The named profile this tab uses; nil follows the default profile.
    @Published var profileID: UUID?
    let legend = SessionLegend()

    var settings: ProfileSettings { TerminalProfile.shared.settings(for: profileID) }

    init(profileID: UUID? = nil) {
        self.profileID = profileID
        view.processDelegate = legend
        applyProfile(settings)
    }

    func applyProfile(_ settings: ProfileSettings) {
        view.font = settings.font
        view.getTerminal().setCursorStyle(settings.cursorStyle)
        view.optionAsMetaKey = settings.optionAsMeta
        view.getTerminal().changeScrollback(settings.scrollbackLines)
        view.bellMode = settings.bell
    }

    private var started = false

    /// The profile's color theme over Basic's light/dark defaults, with its background opacity.
    func applyColors(dark: Bool, settings: ProfileSettings, library: ThemeLibrary = .shared) {
        let theme = library.theme(named: settings.theme)
        let colors = theme?.colors ?? [:]
        let foreground = colors["Foreground Color"] ?? TerminalTypeface.color("TextColor", fallback: dark ? .white : .black)
        view.nativeForegroundColor = foreground
        let background = colors["Background Color"] ?? TerminalTypeface.background(dark: dark)
        view.nativeBackgroundColor = background.withAlphaComponent(background.alphaComponent * settings.backgroundOpacity)
        view.caretTextColor = colors["Cursor Text Color"]
        view.caretColor = colors["Cursor Color"] ?? TerminalTypeface.color("CursorColor", fallback: foreground)
        view.selectedTextBackgroundColor = colors["Selection Color"] ?? TerminalTypeface.color("SelectionColor", fallback: .selectedTextBackgroundColor)
        view.selectedTextForegroundColor = colors["Selected Text Color"] ?? foreground
        view.installColors(theme?.palette ?? SwiftTerm.Color.terminalAppColors)
    }


    func start() {
        guard !started else { return }
        started = true
        if ParityScene.isActive {
            // The scene's shell, starting in the scene's home unless this pane was given a folder.
            let directory = startDirectory == FileManager.default.homeDirectoryForCurrentUser.path ? ParityScene.home.path : startDirectory
            view.startProcess(executable: "/bin/sh", args: [], environment: ParityScene.shellEnvironment().map { "\($0.key)=\($0.value)" },
                              execName: "sh", currentDirectory: directory)
        } else {
            startLoginShell()
        }
        let command = settings.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { view.sendQuietly( command + "\n") }
    }

    private func startLoginShell() {
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "HerbsTerminal"
        environment["SHELL"] = shell
        var arguments: [String] = []
        var execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        if let integrated = ShellIntegration.launch(shell: shell, environment: environment) {
            (environment, arguments, execName) = integrated
        }
        view.startProcess(executable: shell, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: execName, currentDirectory: startDirectory)
    }

    /// The shell's current folder, read from the process itself (shells rarely report it to the terminal).
    var currentDirectory: String? {
        let pid = view.process.shellPid
        guard started, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// The program running in the foreground instead of the shell, if any (Terminal asks before closing it).
    var foregroundProgram: String? {
        guard started, view.process.running else { return nil }
        let group = tcgetpgrp(view.process.childfd)
        guard group > 0, group != view.process.shellPid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func close() {
        if started { view.terminate() }
        started = false
    }

    /// Starts ssh to `endpoint` from this shell. The login becomes the master of a shared connection that
    /// the explorer and transfers reuse; a saved password goes through AskpassBroker.
    ///
    /// Only the path of a private one-shot launcher is typed. The launcher erases that echoed line, deletes
    /// itself and execs ssh, so tokens and options never show on screen or in the shell history.
    func connectSSH(_ endpoint: RemoteEndpoint, password: String?) {
        start()
        var environment: [String: String] = [:]
        if let password, !password.isEmpty, let broker = AskpassBroker.shared {
            environment = broker.environment(token: broker.issue(password, for: SSHControl.passwordLogins(endpoint)))
        }
        let arguments = SSHControl.masterOptions + endpoint.sshArguments()
        do {
            let launcher = try Self.writeLauncher(label: endpoint.label, environment: environment, arguments: arguments)
            // Ctrl-U drops anything half-typed at the prompt; the leading space keeps the line out of
            // history in shells that ignore space-prefixed commands.
            view.sendQuietly( "\u{15} " + shellQuote(launcher.path) + "\n")
        } catch {
            view.feed(text: "\r\nHerb's Terminal couldn't start ssh: \(error.localizedDescription)\r\n")
        }
    }

    static func writeLauncher(label: String, environment: [String: String], arguments: [String],
                              in directory: URL = SSHControl.directory) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let url = directory.appendingPathComponent("c-" + bytes.map { String(format: "%02x", $0) }.joined())
        let exports = environment.keys.sorted().map { "export \($0)=\(shellQuote(environment[$0]!))" }
        let script = (["#!/bin/sh",
                       "printf '\\033[1A\\r\\033[2K'",
                       "rm -f -- \"$0\""]
                      + exports
                      + ["printf '%s\\n' \(shellQuote("Connecting to \(label)…"))",
                         "exec /usr/bin/ssh " + arguments.map(shellQuote).joined(separator: " ")])
            .joined(separator: "\n") + "\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            throw FileIssue("Can't write the ssh launcher in \(directory.path).")
        }
        return url
    }
}

struct ShellPane: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var profiles = TerminalProfile.shared
    @ObservedObject private var themes = ThemeLibrary.shared
    @ObservedObject var session: LocalShell

    func makeNSView(context: Context) -> HerbsTerminalView {
        session.start()
        return session.view
    }

    final class Coordinator {
        var applied: ProfileSettings?
        var scheme: ColorScheme?
        var themeNames: [String] = []
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reapplies the tab's profile when it, the system appearance, or the installed themes change.
    func updateNSView(_ nsView: HerbsTerminalView, context: Context) {
        let settings = session.settings
        let coordinator = context.coordinator
        guard coordinator.applied != settings || coordinator.scheme != colorScheme || coordinator.themeNames != themes.allNames else { return }
        if coordinator.applied != nil, coordinator.applied != settings { session.applyProfile(settings) }
        coordinator.applied = settings
        coordinator.scheme = colorScheme
        coordinator.themeNames = themes.allNames
        session.applyColors(dark: colorScheme == .dark, settings: settings)
    }
}
