import Darwin
import Foundation

/// OpenSSH connection sharing. The tab's interactive ssh is the master; SFTP, transfers, port forwards for
/// remote desktop and multi-host checks ride its socket instead of opening new logins.
enum SSHControl {
    /// Sockets live in a short private folder: a Unix socket path must stay under 104 bytes, and ssh adds a
    /// 17-character temporary suffix to the 40-character %C hash while it sets the master up. A folder under
    /// ~/Library/Caches is too long for that.
    static let directory: URL = privateDirectory(base: "/tmp/herbs-\(getuid())")

    /// %C hashes host, port and user, so the path length doesn't depend on the destination.
    static var controlPath: String { directory.path + "/cm-%C" }

    /// Longest socket path ssh creates: the %C hash is 40 hex characters, plus ".XXXXXXXXXXXXXXXX".
    static var longestSocketPath: Int { directory.path.utf8.count + "/cm-".utf8.count + 40 + 17 }

    /// A folder only this user can use. /tmp is shared, so an existing entry is accepted only when it is a
    /// real directory (not a symlink) owned by this user and closed to everyone else; otherwise a fresh
    /// private name is used.
    static func privateDirectory(base: String) -> URL {
        func isSafe(_ path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
        }
        for candidate in [base] + (1...20).map({ "\(base)-\($0)" }) {
            if mkdir(candidate, 0o700) == 0 || isSafe(candidate) {
                if isSafe(candidate) { return URL(fileURLWithPath: candidate, isDirectory: true) }
            }
        }
        // Last resort: a unique folder from mkdtemp, still short.
        var template = Array("/tmp/herbs-XXXXXX".utf8CString)
        if let made = mkdtemp(&template) { return URL(fileURLWithPath: String(cString: made), isDirectory: true) }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Options for the interactive login. ControlPersist=no ties the master to that session, so leaving
    /// ssh also detaches the explorer.
    static let masterOptions = ["-o", "ControlMaster=auto", "-o", "ControlPersist=no"]

    /// True while a master connection for `endpoint` is up.
    static func isConnected(_ endpoint: RemoteEndpoint) -> Bool {
        run(endpoint.sshArguments(["-O", "check"])) == 0
    }

    @discardableResult
    static func run(_ arguments: [String], environment: [String: String]? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let environment { process.environment = environment }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Quotes a word for a POSIX shell command line.
func shellQuote(_ word: String) -> String {
    if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%,+".contains($0) }) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Hands a saved secret (a password, or a Tailcat address) to ssh once, so it never appears in a command
/// line, the shell history or the terminal. ssh runs Herb's Terminal's own binary as SSH_ASKPASS (see
/// `HelperMode`), which trades a one-time token for the secret over a private Unix socket. Any other
/// prompt (host key, one-time code, a retry after a wrong password) is asked on the terminal as usual.
final class AskpassBroker: @unchecked Sendable {
    static let shared = try? AskpassBroker()

    let socketPath: String
    /// The program ssh runs: this app's own executable, switched into helper mode by HERBSTERMINAL_HELPER.
    let helperPath: String
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private let listener: Int32

    init(directory: URL = SSHControl.directory, helperPath: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) throws {
        let path = directory.appendingPathComponent("askpass-\(getpid()).sock").path
        socketPath = path
        self.helperPath = helperPath
        Self.removeStaleFiles(in: directory)

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FileIssue("Cannot create the password helper socket.") }
        guard var address = unixAddress(path) else { close(fd); throw FileIssue("Password helper path is too long.") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw FileIssue("Cannot start the password helper.") }
        chmod(path, 0o600)
        listener = fd
        Thread.detachNewThread { [self] in serve() }
    }

    /// Sockets of Herb's Terminal processes that are gone, launchers older than a minute, and the shell helper
    /// that earlier builds wrote.
    private static func removeStaleFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix("askpass-"), name.hasSuffix(".sock"),
               let pid = Int32(name.dropFirst(8).dropLast(5)), pid != getpid(), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: url)
            } else if name == "askpass.sh" {
                try? FileManager.default.removeItem(at: url)
            } else if name.hasPrefix("c-"),
                      let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      created.timeIntervalSinceNow < -60 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A one-time token that the helper can exchange for `secret`; it expires after five minutes.
    func issue(_ secret: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock { secrets[token] = secret }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            _ = self?.lock.withLock { self?.secrets.removeValue(forKey: token) }
        }
        return token
    }

    /// Environment that makes ssh ask this broker for the password.
    func environment(token: String) -> [String: String] {
        ["SSH_ASKPASS": helperPath, "SSH_ASKPASS_REQUIRE": "force", "HERBSTERMINAL_HELPER": "askpass",
         "HERBSTERMINAL_SECRET_SOCKET": socketPath, "HERBSTERMINAL_SECRET_TOKEN": token]
    }

    private func serve() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                let token = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let secret = lock.withLock({ secrets.removeValue(forKey: token) }) {
                    let reply = Array((secret + "\n").utf8)
                    _ = reply.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                }
            }
            close(client)
        }
    }

    /// The helper side: exchanges `token` for its secret, or nil if it was used up or expired.
    static func redeem(token: String, socket path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = unixAddress(path) else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array((token + "\n").utf8)
        _ = request.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        guard !reply.isEmpty else { return nil }
        var text = String(decoding: reply, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

private func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    return address
}

/// Modes in which ssh runs Herb's Terminal's own executable, chosen by HERBSTERMINAL_HELPER before any UI starts.
enum HelperMode {
    /// Returns an exit status, or nil when this process is the app itself.
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                    arguments: [String] = CommandLine.arguments) -> Int32? {
        guard let mode = environment["HERBSTERMINAL_HELPER"] else { return nil }
        let token = environment["HERBSTERMINAL_SECRET_TOKEN"] ?? "", socket = environment["HERBSTERMINAL_SECRET_SOCKET"] ?? ""
        switch mode {
        case "askpass":
            let prompt = arguments.count > 1 ? arguments[1] : "Password: "
            guard let answer = askpass(prompt: prompt, token: token, socket: socket) else { return 1 }
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
            return 0
        case "tailcat-proxy":
            // ProxyCommand: become the bundled tailcat, piping ssh to the peer's port.
            guard let address = AskpassBroker.redeem(token: token, socket: socket), let tailcat = Tailcat.executable else { return 1 }
            let port = arguments.count > 1 ? arguments[1] : "22"
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(tailcat), strdup(address), strdup(port), nil]
            execv(tailcat, argv)
            return 127
        default:
            return 2
        }
    }

    static func isSecretPrompt(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["password", "passphrase", "code", "pin", "otp", "token"].contains { lower.contains($0) }
    }

    /// The saved password for ssh's first password prompt; everything else is asked on the terminal.
    static func askpass(prompt: String, token: String, socket: String,
                        terminal: (String, Bool) -> String? = askOnTerminal) -> String? {
        if prompt.lowercased().contains("password"), !token.isEmpty,
           let secret = AskpassBroker.redeem(token: token, socket: socket) {
            return secret
        }
        return terminal(prompt, isSecretPrompt(prompt))
    }

    /// Asks on the controlling terminal; nil when there is none (for example a multi-host run).
    static func askOnTerminal(_ prompt: String, secret: Bool) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = prompt.withCString { write(fd, $0, strlen($0)) }
        var original = termios()
        let canHide = secret && tcgetattr(fd, &original) == 0
        if canHide {
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(fd, TCSAFLUSH, &hidden)
        }
        defer { if canHide { tcsetattr(fd, TCSAFLUSH, &original); _ = write(fd, "\n", 1) } }
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 10, byte != 13 { line.append(byte) }
        return String(decoding: line, as: UTF8.self)
    }
}

/// Whether `pid` has a running child process named `name` (for example the shell's interactive ssh).
func hasChildProcess(of pid: pid_t, named name: String) -> Bool {
    guard pid > 0 else { return false }
    var children = [pid_t](repeating: 0, count: 256)
    guard proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size)) > 0 else { return false }
    for child in children where child > 0 {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(child, &buffer, UInt32(buffer.count))
        if String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == name { return true }
    }
    return false
}
