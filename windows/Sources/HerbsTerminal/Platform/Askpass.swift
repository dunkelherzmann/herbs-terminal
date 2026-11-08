import Foundation
import WinSDK

/// Hands a saved password to ssh once, so it never appears in a command line, the shell history or the
/// terminal. ssh runs Herb's Terminal's own executable as SSH_ASKPASS (see `HelperMode`), which trades a
/// one-time token for the secret over a private named pipe. Any other prompt (host key, one-time code, a retry
/// after a wrong password) is asked on the terminal as usual. This is the Windows counterpart of the Mac and
/// Linux broker, which use a Unix socket.
final class AskpassBroker: @unchecked Sendable {
    static let shared = try? AskpassBroker()

    /// \\.\pipe\herbsterminal-<pid>-<random>; only this Windows account (and SYSTEM) may open it.
    let pipeName: String
    let helperPath: String
    private let lock = NSLock()
    /// A secret and the `user@host` names whose password prompt may receive it.
    private struct Grant { let secret: String; let logins: [String]?; let expires: Date }
    private var secrets: [String: Grant] = [:]
    private let security: UnsafeMutableRawPointer

    init(helperPath: String = AskpassBroker.executablePath) throws {
        pipeName = "\\\\.\\pipe\\herbsterminal-\(GetCurrentProcessId())-\(randomHex(8))"
        self.helperPath = helperPath
        guard let userSID = currentUserSID() else { throw FileIssue("Couldn't read this account's security identifier.") }
        // Protected DACL: full access for this user and SYSTEM, nobody else (not even read access for Everyone,
        // which the default named-pipe DACL grants).
        var descriptor: PSECURITY_DESCRIPTOR?
        let ok = withWide("D:P(A;;GA;;;\(userSID))(A;;GA;;;SY)") {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard ok, let descriptor else { throw FileIssue("Couldn't secure the password helper's pipe.") }
        security = descriptor
        let first = try makeInstance(first: true)
        Thread.detachNewThread { [self] in serve(first) }
    }

    static var executablePath: String {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private func makeInstance(first: Bool) throws -> HANDLE {
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                             lpSecurityDescriptor: security, bInheritHandle: false)
        let openMode = DWORD(PIPE_ACCESS_DUPLEX) | (first ? DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE) : 0)
        let pipeMode = DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT) | DWORD(PIPE_REJECT_REMOTE_CLIENTS)
        let handle = withWide(pipeName) {
            CreateNamedPipeW($0, openMode, pipeMode, DWORD(PIPE_UNLIMITED_INSTANCES), 4096, 4096, 0, &attributes)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw FileIssue("Couldn't start the password helper (error \(GetLastError())).") }
        return handle
    }

    /// A one-time token that the helper can exchange for `secret`; it expires after five minutes. With `logins`
    /// (`user@host` forms), only a prompt for one of them gets it, so a jump host asking first is asked on the
    /// terminal instead and the token waits for the intended host.
    func issue(_ secret: String, for logins: [String]? = nil) -> String {
        let token = randomHex(24)
        lock.withLock {
            let now = Date()
            secrets = secrets.filter { $0.value.expires > now }
            secrets[token] = Grant(secret: secret, logins: logins?.map { $0.lowercased() }, expires: now.addingTimeInterval(300))
        }
        return token
    }

    /// Environment that makes ssh ask this broker for the password.
    func environment(token: String) -> [String: String] {
        ["SSH_ASKPASS": helperPath, "SSH_ASKPASS_REQUIRE": "force", "HERBSTERMINAL_HELPER": "askpass",
         "HERBSTERMINAL_SECRET_PIPE": pipeName, "HERBSTERMINAL_SECRET_TOKEN": token]
    }

    private func serve(_ first: HANDLE) {
        var next: HANDLE? = first
        while true {
            guard let pipe = next ?? (try? makeInstance(first: false)) else { Sleep(200); continue }
            next = nil
            let connected = ConnectNamedPipe(pipe, nil) || GetLastError() == DWORD(ERROR_PIPE_CONNECTED)
            guard connected else { CloseHandle(pipe); continue }
            // Each client on its own thread, so one that connects and stalls can't hold up the next login.
            let value = Int(bitPattern: pipe)
            Thread.detachNewThread { [self] in
                let pipe = HANDLE(bitPattern: value)!
                answer(pipe)
                FlushFileBuffers(pipe)
                DisconnectNamedPipe(pipe)
                CloseHandle(pipe)
            }
        }
    }

    /// One request: "token\nprompt\n".
    private func answer(_ pipe: HANDLE) {
        var request = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.count < 4096, request.filter({ $0 == 10 }).count < 2 {
            var read: DWORD = 0
            guard ReadFile(pipe, &buffer, DWORD(buffer.count), &read, nil), read > 0 else { break }
            request += buffer[0..<Int(read)]
        }
        let lines = String(decoding: request, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let token = lines.first?.trimmingCharacters(in: .whitespaces), !token.isEmpty else { return }
        let prompt = (lines.count > 1 ? lines[1] : "").lowercased()
        let secret: String? = lock.withLock {
            guard let grant = secrets[token], grant.expires > Date() else { return nil }
            if let logins = grant.logins, !logins.contains(where: { AskpassBroker.isPasswordPrompt(prompt, for: $0) }) { return nil }
            secrets.removeValue(forKey: token)
            return grant.secret
        }
        if let secret {
            var reply = Array((secret + "\n").utf8)
            var written: DWORD = 0
            WriteFile(pipe, &reply, DWORD(reply.count), &written, nil)
        }
    }

    /// Whether `prompt` asks for `login`'s password. ssh words it "user@host's password:" for password
    /// authentication and "(user@host) Password:" for keyboard-interactive, which most PAM servers use.
    static func isPasswordPrompt(_ prompt: String, for login: String) -> Bool {
        let prompt = prompt.lowercased(), login = login.lowercased()
        return prompt.contains(login + "'s password") || prompt.contains("(" + login + ") password")
    }

    /// The helper side: exchanges `token` for its secret, or nil if it was used up, expired, or meant for
    /// another host's `prompt`.
    static func redeem(token: String, pipe name: String, prompt: String = "") -> String? {
        var handle: HANDLE?
        for _ in 0..<5 {
            handle = withWide(name) {
                CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let handle, handle != INVALID_HANDLE_VALUE { break }
            handle = nil
            guard GetLastError() == DWORD(ERROR_PIPE_BUSY) else { return nil }
            _ = withWide(name) { WaitNamedPipeW($0, 2000) }
        }
        guard let handle else { return nil }
        defer { CloseHandle(handle) }
        var request = Array((token + "\n" + prompt.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        var written: DWORD = 0
        guard WriteFile(handle, &request, DWORD(request.count), &written, nil) else { return nil }
        var reply = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var read: DWORD = 0
            guard ReadFile(handle, &buffer, DWORD(buffer.count), &read, nil), read > 0 else { break }
            reply += buffer[0..<Int(read)]
        }
        guard !reply.isEmpty else { return nil }
        var text = String(decoding: reply, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

/// Modes in which ssh runs Herb's Terminal's own executable, chosen by HERBSTERMINAL_HELPER before any UI starts.
enum HelperMode {
    /// Returns an exit status, or nil when this process is the app itself.
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                    arguments: [String] = CommandLine.arguments) -> Int32? {
        guard let mode = environment["HERBSTERMINAL_HELPER"] else { return nil }
        guard mode == "askpass" else { return 2 }
        let token = environment["HERBSTERMINAL_SECRET_TOKEN"] ?? "", pipe = environment["HERBSTERMINAL_SECRET_PIPE"] ?? ""
        let prompt = arguments.count > 1 ? arguments[1] : "Password: "
        var answer: String?
        if prompt.lowercased().contains("password"), !token.isEmpty, !pipe.isEmpty {
            answer = AskpassBroker.redeem(token: token, pipe: pipe, prompt: prompt)
        }
        if answer == nil { answer = askOnConsole(prompt, secret: isSecretPrompt(prompt)) }
        guard let answer else { return 1 }
        var bytes = Array((answer + "\n").utf8)
        var written: DWORD = 0
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), &bytes, DWORD(bytes.count), &written, nil)
        return 0
    }

    static func isSecretPrompt(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["password", "passphrase", "code", "pin", "otp", "token"].contains { lower.contains($0) }
    }

    /// Asks in ssh's console (the tab's pseudo console); nil when there is none.
    static func askOnConsole(_ prompt: String, secret: Bool) -> String? {
        guard AttachConsole(DWORD(bitPattern: -1)) else { return nil }
        defer { FreeConsole() }
        let output = withWide("CONOUT$") {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        let input = withWide("CONIN$") {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let output, let input, output != INVALID_HANDLE_VALUE, input != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(output); CloseHandle(input) }
        var written: DWORD = 0
        var units = Array(prompt.utf16)
        WriteConsoleW(output, &units, DWORD(units.count), &written, nil)

        var original: DWORD = 0
        GetConsoleMode(input, &original)
        var mode = DWORD(ENABLE_LINE_INPUT) | DWORD(ENABLE_PROCESSED_INPUT)
        if !secret { mode |= DWORD(ENABLE_ECHO_INPUT) }
        SetConsoleMode(input, mode)
        defer {
            SetConsoleMode(input, original)
            if secret { var newline = Array("\r\n".utf16); WriteConsoleW(output, &newline, 2, &written, nil) }
        }
        var buffer = [WCHAR](repeating: 0, count: 1024)
        var read: DWORD = 0
        guard ReadConsoleW(input, &buffer, DWORD(buffer.count), &read, nil) else { return nil }
        return String(decoding: buffer.prefix(Int(read)), as: UTF16.self).trimmingCharacters(in: .newlines)
    }
}

/// Where a tab's ssh session goes.
struct RemoteEndpoint: Equatable {
    var host: String
    var port: Int
    var username: String

    var label: String { "\(username)@\(host)" }

    /// The names ssh's password prompt uses for this login ("user@host's password:").
    var passwordLogins: [String] { ["\(username)@\(host)"] }
}

enum SSH {
    /// Windows' own OpenSSH client, never a copy found on PATH.
    static var executable: String? {
        let system = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\OpenSSH\\ssh.exe"
        return FileManager.default.fileExists(atPath: system) ? system : nil
    }

    /// A host that is switched off or restarts without closing the connection sends nothing, and TCP alone would
    /// keep the session open for many minutes. ssh asks the server for an answer every 5 seconds and gives up after
    /// 2 missed answers, so the session ends within about 15 seconds, as on the Mac and Linux.
    static let keepAliveOptions = ["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]

    static func commandLine(_ endpoint: RemoteEndpoint) -> String? {
        guard let ssh = executable else { return nil }
        return ([ssh] + keepAliveOptions + ["-p", String(endpoint.port), "\(endpoint.username)@\(endpoint.host)"])
            .map(quoteArgument).joined(separator: " ")
    }
}

/// Quotes one argument the way CommandLineToArgvW and the C runtime read it back.
func quoteArgument(_ argument: String) -> String {
    if !argument.isEmpty, !argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) { return argument }
    var result = "\""
    var backslashes = 0
    for character in argument {
        if character == "\\" {
            backslashes += 1
        } else if character == "\"" {
            result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
            backslashes = 0
        } else {
            result += String(repeating: "\\", count: backslashes) + String(character)
            backslashes = 0
        }
    }
    return result + String(repeating: "\\", count: backslashes * 2) + "\""
}

func randomHex(_ byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// This account's SID as a string ("S-1-5-21-…").
func currentUserSID() -> String? {
    var token: HANDLE?
    guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else { return nil }
    defer { CloseHandle(token) }
    var size: DWORD = 0
    GetTokenInformation(token, TokenUser, nil, 0, &size)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { buffer.deallocate() }
    guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { return nil }
    let user = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
    var text: LPWSTR?
    guard ConvertSidToStringSidW(user.User.Sid, &text), let text else { return nil }
    defer { LocalFree(text) }
    return String(wide: text)
}
