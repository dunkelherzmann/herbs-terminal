import SwiftUI
import SwiftTerm

@MainActor
final class LocalShell: ObservableObject {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                        font: TerminalTypeface.regular, options: TerminalOptions())
    let legend = SessionLegend()

    init() { view.processDelegate = legend }

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
                          currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func close() {
        if started { view.terminate() }
        started = false
    }

    func connectSSH(_ login: SSHLogin) {
        start()
        legend.setRemote(target: "\(login.username)@\(login.host)", location: "/")
        let cmd = "ssh -p \(login.port) \(login.username)@\(login.host)\n"
        view.send(txt: cmd)
    }
}

struct ShellPane: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let session: LocalShell
    let theme: TerminalTheme?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.start()
        return session.view
    }

    final class Coordinator {
        var scheme: ColorScheme?
        var theme: TerminalTheme?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        guard context.coordinator.scheme != colorScheme || context.coordinator.theme !== theme else { return }
        context.coordinator.scheme = colorScheme
        context.coordinator.theme = theme
        session.applyColors(dark: colorScheme == .dark, theme: theme)
    }
}
