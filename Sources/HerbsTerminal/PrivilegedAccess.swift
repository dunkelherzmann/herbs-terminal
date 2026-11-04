import AppKit
import Foundation

/// Administrator mode for the explorers. The system SFTP server is started under sudo, on this Mac or on
/// the tab's host over its shared SSH connection, and the explorer talks to it like any remote host: every
/// action then runs as root. The password reaches sudo once on standard input (`sudo -S`), never in a
/// command line, and isn't kept. Accounts with password-free sudo aren't asked.
enum PrivilegedAccess {
    enum Target: Equatable, Sendable {
        case local
        case remote(RemoteEndpoint)

        var label: String {
            switch self {
            case .local: "this Mac"
            case .remote(let endpoint): endpoint.host
            }
        }
    }

    /// Finds the host's SFTP server, wherever its OpenSSH package put it.
    static let remoteServer = """
    for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server \
    /usr/libexec/sftp-server /usr/lib/sftp-server /usr/sbin/sftp-server; do \
    if [ -x "$p" ]; then exec "$p"; fi; done; echo "no sftp-server found" >&2; exit 127
    """

    /// The program and arguments that run `sudo <sudoArguments> <command>` on `target`.
    static func invocation(_ target: Target, sudo sudoArguments: [String], command: [String]) -> (String, [String]) {
        switch target {
        case .local:
            return ("/usr/bin/sudo", sudoArguments + command)
        case .remote(let endpoint):
            let remote = (["sudo"] + sudoArguments + command).map(shellQuote).joined(separator: " ")
            return ("/usr/bin/ssh", endpoint.sshArguments(["-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes", "-T"]) + [remote])
        }
    }

    private static func serverCommand(_ target: Target) -> [String] {
        target == .local ? ["/usr/libexec/sftp-server"] : ["sh", "-c", remoteServer]
    }

    /// Runs sudo with `input` on standard input; nil exit status on timeout.
    static func run(_ target: Target, sudo sudoArguments: [String], command: [String] = [], input: String? = nil,
                    timeout: TimeInterval = 20) -> Int32? {
        let (executable, arguments) = invocation(target, sudo: sudoArguments, command: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + timeout) == .success else { process.terminate(); return nil }
        return process.terminationStatus
    }

    /// True unless sudo works without a password for this account.
    static func needsPassword(_ target: Target) -> Bool {
        run(target, sudo: ["-n", "-v"]) != 0
    }

    /// Checks the password on its own first: a wrong one must never reach the SFTP session, where sudo
    /// would wait for another attempt.
    static func check(_ target: Target, password: String) -> Bool {
        run(target, sudo: ["-S", "-k", "-v", "-p", ""], input: password + "\n") == 0
    }

    /// Starts the root SFTP session. `password` is nil for password-free sudo.
    static func openSession(_ target: Target, password: String?) throws -> SFTPClient {
        let sudo = password == nil ? ["-n"] : ["-S", "-k", "-p", ""]
        let (executable, arguments) = invocation(target, sudo: sudo, command: serverCommand(target))
        do {
            return try SFTPClient(executable: executable, arguments: arguments, preamble: password.map { Data(($0 + "\n").utf8) })
        } catch {
            throw FileIssue("Couldn't start the administrator session on \(target.label): \(error.localizedDescription)")
        }
    }
}

/// Turns Administrator mode on and off for a tab's explorer.
@MainActor
enum AdministratorMode {
    static func enter(_ state: WindowState) async {
        let target: PrivilegedAccess.Target
        let start: String
        if case .remote(let endpoint) = state.endpoint {
            target = .remote(endpoint)
            start = state.remoteDirectory
        } else {
            target = .local
            start = state.directory.path
        }
        let needs = await Task.detached { PrivilegedAccess.needsPassword(target) }.value
        var password: String?
        if needs {
            guard let entered = askPassword(for: target) else { return }
            guard await Task.detached(operation: { PrivilegedAccess.check(target, password: entered) }).value else {
                report("That password didn't work, or this account can't use sudo on \(target.label).")
                return
            }
            password = entered
        }
        let typed = password
        do {
            let client = try await Task.detached { try PrivilegedAccess.openSession(target, password: typed) }.value
            let host: String
            switch target {
            case .local: host = "this Mac"
            case .remote(let endpoint): host = endpoint.host
            }
            state.adminViewModel = RemoteExplorerViewModel(administrator: client, endpoint: RemoteEndpoint(host: host, username: "root"))
            state.adminTarget = target
            state.adminPath = start
            state.adminHistory = NavigationHistory(start)
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Ends the root session; the explorer goes back to the user's own access.
    static func leave(_ state: WindowState) {
        if state.adminTarget == .local, FileManager.default.isReadableFile(atPath: state.adminPath) {
            state.directory = URL(fileURLWithPath: state.adminPath, isDirectory: true)
        } else if case .remote = state.adminTarget {
            state.remoteDirectory = state.adminPath
        }
        state.adminViewModel = nil
        state.adminTarget = nil
    }

    private static func askPassword(for target: PrivilegedAccess.Target) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Administrator Mode on \(target.label)"
        alert.informativeText = target == .local
            ? "Enter your Mac password. While Administrator mode is on, the explorer works as root: it can open and change any file."
            : "Enter the sudo password for your account on \(target.label). While Administrator mode is on, the explorer works as root there."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Enter Administrator Mode")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Administrator mode isn't available"
        alert.informativeText = message
        alert.runModal()
    }
}
