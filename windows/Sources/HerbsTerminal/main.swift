import Foundation
import WinSDK

// The app is a GUI-subsystem program, so it has no console of its own. Command-line modes borrow the console of
// the shell that started them, unless their output already goes to a pipe or file.
func attachParentConsole() {
    let out = GetStdHandle(STD_OUTPUT_HANDLE)
    if out == nil || out == INVALID_HANDLE_VALUE, AttachConsole(DWORD(bitPattern: -1)) {
        _ = freopen("CONOUT$", "w", stdout)
        _ = freopen("CONOUT$", "w", stderr)
    }
}

// ssh runs this same executable as its SSH_ASKPASS helper; that mode never opens a window.
if let status = HelperMode.run() { exit(status) }
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == SFTPRelay.flag {
    exit(SFTPRelay.run(Array(CommandLine.arguments.dropFirst(2))))
}

// A parity scene keeps its files in a private folder; that has to be set before any store opens.
ParityScene.prepare()

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--self-test") {
        attachParentConsole()
        let code = SelfTest.run()
        fflush(stdout)
        exit(code)
    }
    App.run()
}
