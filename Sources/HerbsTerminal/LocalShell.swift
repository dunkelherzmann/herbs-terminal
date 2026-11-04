import SwiftUI
import SwiftTerm

@MainActor
final class LocalShell: ObservableObject {
    let view = HerbsTerminalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                    font: TerminalProfile.shared.font,
                                    options: TerminalOptions(scrollback: TerminalProfile.shared.scrollbackLines))
    /// Where the login shell starts; new tabs pass the current tab's folder.
    var startDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    let legend = SessionLegend()

    init() {
        view.processDelegate = legend
        applyProfile(TerminalProfile.shared)
    }

    func applyProfile(_ profile: TerminalProfile) {
        view.font = profile.font
        view.getTerminal().setCursorStyle(profile.cursorStyle)
        view.optionAsMetaKey = profile.optionAsMeta
        view.getTerminal().changeScrollback(profile.scrollbackLines)
        view.bellMode = profile.bell
    }

    private var started = false

    func applyColors(dark: Bool, theme: TerminalTheme? = nil) {
        // Basic leaves unarchived colors to the light/dark defaults.
        let colors = theme?.colors ?? [:]
        let foreground = colors["Foreground Color"] ?? TerminalTypeface.color("TextColor", fallback: dark ? .white : .black)
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = colors["Background Color"] ?? TerminalTypeface.background(dark: dark)
        view.caretTextColor = colors["Cursor Text Color"]
        view.caretColor = colors["Cursor Color"] ?? TerminalTypeface.color("CursorColor", fallback: foreground)
        view.selectedTextBackgroundColor = colors["Selection Color"] ?? TerminalTypeface.color("SelectionColor", fallback: .selectedTextBackgroundColor)
        view.selectedTextForegroundColor = colors["Selected Text Color"] ?? foreground
        view.installColors(theme?.palette ?? SwiftTerm.Color.terminalAppColors)
    }

    func start() {
        guard !started else { return }
        started = true
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "HerbsTerminal"
        environment["SHELL"] = shell
        view.startProcess(executable: shell, environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                          currentDirectory: startDirectory)
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
        return String(cString: name)
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
            environment = broker.environment(token: broker.issue(password))
        }
        let arguments = SSHControl.masterOptions + endpoint.sshArguments()
        do {
            let launcher = try Self.writeLauncher(label: endpoint.label, environment: environment, arguments: arguments)
            // Ctrl-U drops anything half-typed at the prompt; the leading space keeps the line out of
            // history in shells that ignore space-prefixed commands.
            view.send(txt: "\u{15} " + shellQuote(launcher.path) + "\n")
        } catch {
            view.feed(text: "\r\nHerbsTerminal couldn't start ssh: \(error.localizedDescription)\r\n")
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
    @ObservedObject private var profile = TerminalProfile.shared
    let session: LocalShell
    let theme: TerminalTheme?

    func makeNSView(context: Context) -> HerbsTerminalTerminalView {
        session.start()
        return session.view
    }

    final class Coordinator {
        var scheme: ColorScheme?
        var theme: TerminalTheme?
        var profile: String?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ nsView: HerbsTerminalTerminalView, context: Context) {
        // A profile edit resets this tab's Bigger/Smaller zoom, as in Terminal.
        if context.coordinator.profile != profile.signature {
            if context.coordinator.profile != nil { session.applyProfile(profile) }
            context.coordinator.profile = profile.signature
        }
        guard context.coordinator.scheme != colorScheme || context.coordinator.theme !== theme else { return }
        context.coordinator.scheme = colorScheme
        context.coordinator.theme = theme
        session.applyColors(dark: colorScheme == .dark, theme: theme)
    }
}
