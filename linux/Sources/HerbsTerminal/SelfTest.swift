import Foundation
import Glibc

#if DEBUG
// Checks for the Linux layer: the compatibility modules the shared macOS code runs on, the host bridge, the login
// vault, file operations, and (when HERBS_TEST_SSH names a reachable account) a real SSH and SFTP round trip.

enum CryptoCompatibility {
    /// RFC 7914 §11's PBKDF2-HMAC-SHA256 vector: the same derivation CommonCrypto does on a Mac.
    @MainActor static func pbkdf2MatchesTheStandardVector() throws {
        let key = try CredentialStore.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        let bytes = key.withUnsafeBytes { Array($0) }
        expect(bytes.map { String(format: "%02x", $0) }.joined().hasPrefix("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"))
    }

    @MainActor static func aesGCMRoundTripsAndRejectsTampering() throws {
        let vault = CryptoVault(keyProvider: StaticKeyProvider(key: .init(size: .bits256)))
        let sealed = try vault.encrypt("correct horse")
        expect(sealed.nonce.count == 12 && sealed.tag.count == 16)
        expect(try vault.decrypt(sealed) == "correct horse")
        var tampered = sealed
        tampered.ciphertext[0] ^= 1
        expectThrows { _ = try vault.decrypt(tampered) }
    }

    @MainActor static func randomBytesAreFilled() throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        expect(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == 0)
        expect(bytes.contains { $0 != 0 })
    }
}

enum VaultOnLinux {
    @MainActor static func adminPasswordEncryptsAndUnlocks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try CredentialStore(databaseURL: file, iterations: 1000)
        try store.setAdminPassword("long enough password")
        try store.save(SSHLogin(host: "Example.org", port: 22, username: "ops", password: "s3cret"))
        let reopened = try CredentialStore(databaseURL: file, iterations: 1000)
        expect(reopened.isLocked)
        expectThrows { try reopened.unlock("wrong password") }
        try reopened.unlock("long enough password")
        expect(reopened.logins.first?.password == "s3cret")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(mode == 0o600)
    }
}

enum AskpassOnLinux {
    /// The broker answers only this account (SO_PEERCRED) and hands each secret out once.
    @MainActor static func tokenRedeemsOnce() throws {
        let folder = URL(fileURLWithPath: "/tmp/herbs-test-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broker = try AskpassBroker(directory: folder, helperPath: "/bin/false")
        let token = broker.issue("pa55word", for: ["ops@host"])
        expect(AskpassBroker.redeem(token: token, socket: broker.socketPath, prompt: "other@elsewhere's password: ") == nil)
        expect(AskpassBroker.redeem(token: token, socket: broker.socketPath, prompt: "ops@host's password: ") == "pa55word")
        expect(AskpassBroker.redeem(token: token, socket: broker.socketPath, prompt: "ops@host's password: ") == nil)
    }

    @MainActor static func launcherIsPrivateAndQuotesArguments() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try MainActor.assumeIsolated {
            try TerminalPane.writeLauncher(label: "ops@host", environment: ["SSH_ASKPASS": "/a b"], arguments: ["-p", "22", "ops@host"], in: folder)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        expect(text.contains("export SSH_ASKPASS='/a b'"))
        expect(text.contains("exec /usr/bin/ssh -p 22 ops@host"))
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(mode == 0o700)
    }
}

enum HostBridge {
    @MainActor static func reportsAProcessFolderAndForeground() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        try process.run()
        defer { process.terminate() }
        let report = HostProcesses.shared.report(for: process.processIdentifier)
        expect(report?.directory == "/tmp")
        expect(report?.runsSSH == false)
    }

    @MainActor static func systemFoldersMapIntoTheSandbox() throws {
        expect(Host.sandboxPath("/home/me/file") == "/home/me/file")
    }
}

enum LocalFilesOnLinux {
    @MainActor static func trashAndUndoPutsTheFileBack() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("herbs-trash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let change = try LocalFiles.trash([file])
        expect(!FileManager.default.fileExists(atPath: file.path))
        guard case .trashed(let moves) = change else { fail("not a trash change"); return }
        let info = moves[0].to.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("info/" + moves[0].to.lastPathComponent + ".trashinfo")
        expect(try String(contentsOf: info, encoding: .utf8).contains("Path=" + file.path))
        _ = try LocalFiles.revert(change)
        expect(FileManager.default.fileExists(atPath: file.path))
        expect(!FileManager.default.fileExists(atPath: info.path))
    }

    @MainActor static func copiesGetFreeNames() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.txt")
        try Data().write(to: file)
        guard case .created(let made) = try LocalFiles.copy([file], into: folder) else { fail("no copy"); return }
        expect(made.first?.lastPathComponent == "a copy.txt")
    }

    @MainActor static func permissionsChangeLocally() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try LocalFileInfo.apply(FileInfoChange(mode: 0o640), to: [file])
        expect(try LocalFileInfo.load(file).mode == 0o640)
        expect(symbolicMode(0o4755) == "rwsr-xr-x")
    }
}

enum ThemesAndText {
    @MainActor static func readsAnITermPresetAndRejectsDamage() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>Background Color</key><dict><key>Red Component</key><real>0.1</real><key>Green Component</key><real>0.2</real><key>Blue Component</key><real>0.3</real></dict>
        </dict></plist>
        """
        let theme = try TerminalTheme(data: Data(plist.utf8))
        expect(theme.colors["Background Color"]?.blue == 0.3)
        expectThrows { _ = try TerminalTheme(data: Data("<plist><dict><key>Background Color</key><string>x</string></dict></plist>".utf8)) }
    }

    @MainActor static func textDetection() throws {
        expect(TextCodec.isText(name: "notes.md") { nil })
        expect(!TextCodec.isText(name: "photo.png") { Data("x".utf8) })
        expect(TextCodec.isText(name: "Makefile") { Data("all:\n".utf8) })
        expect(TextCodec.decode(Data([0x41, 0x00, 0x42])) == nil)
    }

    @MainActor static func sessionNamesAndRedaction() throws {
        expect(sessionFileName(title: "a/b", date: Date(timeIntervalSince1970: 0)).hasPrefix("a-b 1970-01-01"))
        expect(redactCredentials("curl https://user:pw@host --password=x") == "curl https://user:•••@host --password=•••")
    }
}

/// A real login: HERBS_TEST_SSH=user@host:port:password names a test account. The interactive ssh becomes the
/// shared-connection master with the saved password from the broker, then SFTP lists and writes over it.
enum LiveSSH {
    static let account = ProcessInfo.processInfo.environment["HERBS_TEST_SSH"]
    static let helper = ProcessInfo.processInfo.environment["HERBS_TEST_HELPER"]

    @MainActor static func passwordLoginSharedConnectionAndSFTP() throws {
        guard let account, !account.isEmpty, let helper else { print("skipped: passwordLoginSharedConnectionAndSFTP"); return }
        // user@host:port:password; anything else is a failed check, not a crash.
        let parts = account.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let login = parts[0].split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, login.count == 2, !login[0].isEmpty, !login[1].isEmpty else {
            print("HERBS_TEST_SSH must be user@host:port:password")
            expect(false)
            return
        }
        let endpoint = RemoteEndpoint(host: login[1], port: Int(parts[1]) ?? 22, username: login[0])
        let broker = try AskpassBroker(helperPath: helper)
        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        master.arguments = ["-o", "ControlMaster=yes", "-o", "ControlPersist=20", "-o", "StrictHostKeyChecking=no",
                            "-o", "UserKnownHostsFile=/dev/null", "-fN"] + endpoint.sshArguments()
        var environment = ProcessInfo.processInfo.environment
        environment.merge(broker.environment(token: broker.issue(parts[2], for: SSHControl.passwordLogins(endpoint)))) { $1 }
        master.environment = environment
        master.standardInput = FileHandle.nullDevice
        try master.run()
        master.waitUntilExit()
        expect(master.terminationStatus == 0)
        defer { SSHControl.run(endpoint.sshArguments(["-O", "exit"])) }
        expect(SSHControl.isConnected(endpoint))
        let client = try SFTPClient(endpoint: endpoint)
        let home = try client.canonical(".")
        let name = "herbs-test-\(UUID().uuidString.prefix(6)).txt"
        try SFTPTransfer(client: client).replace(remoteJoin(home, name), with: Data("hi".utf8)) // creates via rename
        expect(try client.list(home).contains { $0.name == name })
        expect(try SFTPTransfer(client: client).readAll(remoteJoin(home, name), limit: 100) == Data("hi".utf8))
        try client.remove(remoteJoin(home, name))
    }
}

/// ChildProcess waits on its own child, so short commands end when they end, even in the app where GLib also
/// handles SIGCHLD.
enum ShortCommands {
    static func reportStatusOutputAndTimeLimit() {
        expect(ChildProcess.run(["/bin/sh", "-c", "exit 3"]).status == 3)
        let echoed = ChildProcess.run(["/bin/cat"], input: Data("hello".utf8))
        expect(echoed.status == 0 && echoed.output == Data("hello".utf8))
        expect(ChildProcess.run(["/bin/sh", "-c", "echo out; echo err >&2"], errors: true).output == Data("out\nerr\n".utf8))
        expect(ChildProcess.run(["/bin/sh", "-c", "echo err >&2"]).output.isEmpty)
        let started = Date()
        expect(ChildProcess.run(["/bin/sleep", "5"], timeout: 0.5).status == nil)
        expect(Date().timeIntervalSince(started) < 2)
        expect(ChildProcess.run(["/nonexistent/program"]).status == nil)
        // Many in a row return as soon as each command ends, not at its time limit.
        let quick = Date()
        for _ in 0..<20 { expect(Host.run(["/bin/true"], timeout: 5).status == 0) }
        expect(Date().timeIntervalSince(quick) < 5)
    }
}

nonisolated(unsafe) var selfTestFailures = 0

func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    let passed = (try? condition()) ?? false
    if !passed { selfTestFailures += 1; print("✘ \(file):\(line)") }
}

func expectThrows(_ body: () throws -> Void, file: String = #fileID, line: Int = #line) {
    do { try body(); selfTestFailures += 1; print("✘ \(file):\(line) didn't throw") } catch {}
}

func fail(_ message: String, file: String = #fileID, line: Int = #line) { selfTestFailures += 1; print("✘ \(file):\(line) \(message)") }

/// `herbs-terminal --self-test` in a debug build: runs the checks and exits with the number of failures.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        let checks: [(String, () throws -> Void)] = [
            ("PBKDF2 standard vector", CryptoCompatibility.pbkdf2MatchesTheStandardVector),
            ("AES-GCM round trip", CryptoCompatibility.aesGCMRoundTripsAndRejectsTampering),
            ("random bytes", CryptoCompatibility.randomBytesAreFilled),
            ("vault Administrator Password", VaultOnLinux.adminPasswordEncryptsAndUnlocks),
            ("askpass token", AskpassOnLinux.tokenRedeemsOnce),
            ("ssh launcher", AskpassOnLinux.launcherIsPrivateAndQuotesArguments),
            ("host process report", HostBridge.reportsAProcessFolderAndForeground),
            ("sandbox paths", HostBridge.systemFoldersMapIntoTheSandbox),
            ("trash and undo", LocalFilesOnLinux.trashAndUndoPutsTheFileBack),
            ("copy names", LocalFilesOnLinux.copiesGetFreeNames),
            ("local permissions", LocalFilesOnLinux.permissionsChangeLocally),
            ("iTerm2 presets", ThemesAndText.readsAnITermPresetAndRejectsDamage),
            ("text detection", ThemesAndText.textDetection),
            ("session names and redaction", ThemesAndText.sessionNamesAndRedaction),
            ("short commands", ShortCommands.reportStatusOutputAndTimeLimit),
            ("live SSH and SFTP", LiveSSH.passwordLoginSharedConnectionAndSFTP),
        ]
        for (name, check) in checks {
            let before = selfTestFailures
            do { try check() } catch { selfTestFailures += 1; print("✘ \(name): \(error)") }
            print(selfTestFailures == before ? "✔ \(name)" : "✘ \(name)")
        }
        print(selfTestFailures == 0 ? "All checks passed." : "\(selfTestFailures) check(s) failed.")
        return Int32(selfTestFailures)
    }
}
#endif
