import Foundation

/// Administrator mode for the explorers. The system SFTP server is started under sudo, on this computer or on the
/// tab's host over its shared SSH connection, and the explorer talks to it like any remote host: every action then
/// runs as root. The password reaches sudo once on standard input (`sudo -S`), never in a command line, and isn't
/// kept. Accounts with password-free sudo aren't asked.
enum PrivilegedAccess {
    enum Target: Equatable, Sendable {
        case local
        case remote(RemoteEndpoint)

        var label: String {
            switch self {
            case .local: "this computer"
            case .remote(let endpoint): endpoint.host
            }
        }
    }

    /// Finds the SFTP server, wherever its OpenSSH package put it.
    static let serverSearch = """
    for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server \
    /usr/libexec/sftp-server /usr/lib/sftp-server /usr/sbin/sftp-server; do \
    if [ -x "$p" ]; then exec "$p"; fi; done; echo "no sftp-server found" >&2; exit 127
    """

    /// The program and arguments that run `sudo <sudoArguments> <command>` on `target`.
    static func invocation(_ target: Target, sudo sudoArguments: [String], command: [String]) -> (String, [String]) {
        switch target {
        case .local:
            let full = Host.argv(["/usr/bin/sudo"] + sudoArguments + command)
            return (full[0], Array(full.dropFirst()))
        case .remote(let endpoint):
            let remote = (["sudo"] + sudoArguments + command).map(shellQuote).joined(separator: " ")
            return ("/usr/bin/ssh", endpoint.sshArguments(["-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes", "-T"]) + [remote])
        }
    }

    private static func serverCommand(_ target: Target) -> [String] { ["/bin/sh", "-c", serverSearch] }

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

    /// Checks the password on its own first: a wrong one must never reach the SFTP session, where sudo would
    /// wait for another attempt.
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
