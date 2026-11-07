import AppKit
import CryptoKit
import SQLite3
import Foundation
import Testing
@testable import HerbsTerminal

// Regressions found by the ECC review: each test fails on the code as it was before the fix.

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-qa-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private func localSFTP() throws -> SFTPClient { try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: []) }

private let testKey = SymmetricKey(size: .bits256)

@MainActor
private func store(at url: URL) throws -> CredentialStore {
    try CredentialStore(databaseURL: url, vault: CryptoVault(keyProvider: StaticKeyProvider(key: testKey)))
}

@Test @MainActor
func aHostSpelledDifferentlyReplacesItsLoginInsteadOfDuplicatingIt() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let logins = try store(at: root.appendingPathComponent("logins.sqlite3"))
    try logins.save(SSHLogin(host: "nas.local", port: 22, username: "herb", password: "old"))
    try logins.save(SSHLogin(host: "NAS.local", port: 22, username: "herb", password: "new"))
    #expect(logins.logins.count == 1)
    #expect(logins.get(id: SSHLogin(host: "nas.local", port: 22, username: "herb", password: "").id)?.password == "new")
}

@Test @MainActor
func theFallbackStoreWorksInMemoryOnly() throws {
    let fallback = CredentialStore.unavailable()
    try fallback.save(SSHLogin(host: "h", port: 22, username: "u", password: "p"))
    #expect(fallback.logins.count == 1)
    #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/:memory:"))
}

@Test
func remoteCopyAndDownloadSkipFolderLinksInsideTheTree() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: tree.appendingPathComponent("file.txt"))
    try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("loop").path, withDestinationPath: "..")
    try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("alias.txt").path, withDestinationPath: "file.txt")

    let transfer = SFTPTransfer(client: try localSFTP())
    try transfer.copy(tree.path, to: root.appendingPathComponent("copy").path)
    try transfer.download(tree.path, to: root.appendingPathComponent("down"))

    for folder in ["copy", "down"] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).sorted()
        #expect(names == ["alias.txt", "file.txt"])
    }
}

@Test
func uploadsNeverWriteThroughAPlantedPartFile() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let victim = root.appendingPathComponent("victim")
    try Data("keep".utf8).write(to: victim)
    // What an attacker could plant under the old, predictable part name.
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".up.txt.herbsterminal-part").path, withDestinationPath: victim.path)
    let local = root.appendingPathComponent("source.txt")
    try Data("upload".utf8).write(to: local)
    try FileManager.default.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: local.path)

    try SFTPTransfer(client: try localSFTP()).upload(local, to: root.appendingPathComponent("up.txt").path)

    #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    #expect(try Data(contentsOf: root.appendingPathComponent("up.txt")) == Data("upload".utf8))
    let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("up.txt").path)[.posixPermissions] as? Int
    #expect(mode.map { $0 & 0o7000 } == 0)
}

@Test @MainActor
func remoteFoldersCannotBePastedIntoThemselves() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let model = RemoteExplorerViewModel(endpoint: RemoteEndpoint(host: "localhost", username: "me"),
                                        service: try localSFTP(), makeClient: { try localSFTP() }, queue: TransferQueue())
    await model.paste([project.path], cut: false, into: project.path)
    #expect(model.alert?.contains("into itself") == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
}

@Test @MainActor
func unreadableProfilesAreKeptInsteadOfOverwritten() throws {
    let suite = "qa-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not json".utf8), forKey: "terminalProfiles")
    let profile = TerminalProfile(defaults: defaults)
    #expect(profile.profiles.map(\.name) == ["Basic"])
    let kept = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("terminalProfiles.unreadable-") }
    #expect(kept.count == 1)
}

@Test @MainActor
func unreadableTailcatPeersAreSetAside() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tailcat-peers.json")
    try Data("{broken".utf8).write(to: file)
    let peers = TailcatPeerStore(file: file, secrets: nil)
    #expect(peers.peers.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("unreadable") })
}

@Test @MainActor
func manageLoginsKnowsWhichLoginsArePlainText() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let logins = try CredentialStore(databaseURL: root.appendingPathComponent("logins.sqlite3"), iterations: 1000)
    try logins.choosePlainText()
    let plain = SSHLogin(host: "nas.local", port: 22, username: "herb", password: "pw")
    try logins.save(plain)
    #expect(logins.plainTextIDs == [plain.id])
    // Once an Administrator Password is set, every login is encrypted.
    try logins.setAdminPassword("correct horse battery")
    #expect(logins.plainTextIDs.isEmpty && logins.logins.count == 1)
    // Locked, the encrypted ones are hidden and counted.
    logins.lock()
    #expect(logins.logins.isEmpty && logins.lockedCount == 1)
}

@Test @MainActor
func anAdministratorPasswordSetByAnEarlierBuildStillUnlocks() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("logins.sqlite3")
    let first = try CredentialStore(databaseURL: url, iterations: 1000)
    try first.setAdminPassword("correct horse battery")
    try first.save(SSHLogin(host: "nas.local", port: 22, username: "herb", password: "pw"))

    // Rewrite the stored check value the way an earlier build did, with another prefix.
    var db: OpaquePointer?
    try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    func meta(_ key: String) -> Data? {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
    let salt = try #require(meta("salt"))
    let rounds = try #require(meta("iterations").flatMap { Int(String(decoding: $0, as: UTF8.self)) })
    let key = try CredentialStore.deriveKey(password: "correct horse battery", salt: salt, iterations: rounds)
    let old = try CryptoVault(keyProvider: StaticKeyProvider(key: key)).encrypt("earlier-admin-password-check-v1")
    let combined = old.nonce + old.tag + old.ciphertext
    var update: OpaquePointer?
    sqlite3_prepare_v2(db, "UPDATE meta SET value = ? WHERE key = 'check';", -1, &update, nil)
    _ = combined.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32(combined.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    #expect(sqlite3_step(update) == SQLITE_DONE)
    sqlite3_finalize(update)

    let reopened = try CredentialStore(databaseURL: url, iterations: 1000)
    #expect(reopened.isLocked && reopened.verify("correct horse battery") && !reopened.verify("wrong"))
    try reopened.unlock("correct horse battery")
    #expect(reopened.logins.map(\.host) == ["nas.local"])
    // The check value was upgraded, so it keeps working.
    #expect(meta("check") != combined)
    #expect(try CredentialStore(databaseURL: url, iterations: 1000).verify("correct horse battery"))
}

@Test @MainActor
func removingTheAdministratorPasswordLeavesReadablePlainTextLoginsAndAddresses() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let logins = try CredentialStore(databaseURL: root.appendingPathComponent("logins.sqlite3"), iterations: 1000)
    try logins.setAdminPassword("correct horse battery")
    let login = SSHLogin(host: "nas.local", port: 22, username: "herb", password: "pw")
    try logins.save(login)
    let peers = TailcatPeerStore(file: root.appendingPathComponent("peers.json"), secrets: logins)
    try peers.add(name: "office", username: "herb", address: "secret-address", persistent: false)
    #expect(peers.peers[0].secret.first == 1)   // encrypted

    #expect(throws: (any Error).self) { try logins.removeAdminPassword(current: "wrong password") }
    try peers.reprotect { try logins.removeAdminPassword(current: "correct horse battery") }
    #expect(logins.protection == .plainText && !logins.isLocked)
    #expect(logins.plainTextIDs == [login.id] && logins.get(id: login.id)?.password == "pw")
    #expect(!logins.verify("correct horse battery"))
    #expect(peers.peers[0].secret.first == 0)
    #expect(try logins.reveal(peers.peers[0].secret) == "secret-address")
    // Setting a new one encrypts both again.
    try peers.reprotect { try logins.setAdminPassword("another good password") }
    #expect(peers.peers[0].secret.first == 1 && logins.plainTextIDs.isEmpty)
    #expect(try logins.reveal(peers.peers[0].secret) == "secret-address")
}

@Test @MainActor
func exportIncludesOnlyTheTickedLogins() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let logins = try CredentialStore(databaseURL: root.appendingPathComponent("logins.sqlite3"), iterations: 1000)
    try logins.choosePlainText()
    let a = SSHLogin(host: "a.local", port: 22, username: "u", password: "1"), b = SSHLogin(host: "b.local", port: 22, username: "u", password: "2")
    try logins.save(a)
    try logins.save(b)
    let csv = String(decoding: try logins.exportCSV(only: [b.id]), as: UTF8.self)
    #expect(csv.contains("b.local") && !csv.contains("a.local"))
}

@Test @MainActor
func remoteItemsPasteIntoFinderAsRealFiles() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("report.txt")
    try Data("remote bytes".utf8).write(to: source)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("herbs-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboard = FileClipboard(pasteboard: pasteboard)
    let endpoint = RemoteEndpoint(host: "localhost", username: "me")
    clipboard.writeRemote([source.path], on: endpoint, cut: false) { path, target in
        try SFTPTransfer(client: try SFTPClient(executable: "/usr/libexec/sftp-server", arguments: [])).download(path, to: target)
    }
    // Herb's Terminal still sees remote items…
    #expect(clipboard.readRemote(for: endpoint)?.paths == [source.path])
    // …and Finder, or the local explorer, gets a real file with the remote file's bytes.
    let urls = clipboard.readLocal().urls
    #expect(urls.count == 1 && urls[0].lastPathComponent == "report.txt")
    #expect(try Data(contentsOf: urls[0]) == Data("remote bytes".utf8))
}

@Test @MainActor
func typingExitClosesThePaneThenTheTab() async throws {
    let workspace = Workspace(restoring: nil)
    defer { workspace.tabs.forEach { $0.shells.forEach { $0.close() } } }
    workspace.add()
    let (first, second) = (workspace.tabs[0], workspace.tabs[1])
    workspace.split(.horizontal, in: second)
    let pane = second.shells[1]
    workspace.shellExited(pane, in: second)
    #expect(second.shells.count == 1 && workspace.tabs.count == 2)
    workspace.shellExited(second.shells[0], in: second)
    #expect(workspace.tabs.count == 1 && workspace.selected === first)
    // A shell the app closed itself (already gone from its tab) changes nothing.
    workspace.shellExited(pane, in: first)
    #expect(workspace.tabs.count == 1)
}

@Test @MainActor
func tailcatPanelStartsEmptyWithOneTimeChosen() {
    let form = TailcatForm()
    #expect(form.username.isEmpty && !form.persistent && !form.sharePersistent)
    form.name = "x"; form.username = "Herbert"; form.address = "secret"; form.persistent = true
    form.clear()
    #expect(form.name.isEmpty && form.username.isEmpty && form.address.isEmpty && !form.persistent)
}

@Test @MainActor
func exportSessionSavesTheWholeTextUnderTheTabNameAndTime() throws {
    let shell = LocalShell()
    for index in 1...150 { shell.view.feed(text: "line \(index)\r\n") }   // more than a screen: scrollback too
    shell.view.feed(text: "last line")
    let text = Workspace.sessionText(shell)
    #expect(text.hasPrefix("line 1\n") && text.contains("line 150\n") && text.hasSuffix("last line\n"))

    var parts = DateComponents()
    parts.year = 2026; parts.month = 11; parts.day = 6; parts.hour = 9; parts.minute = 5
    let date = try #require(Calendar.current.date(from: parts))
    #expect(Workspace.sessionFileName(title: "Terminal 2", date: date) == "Terminal 2 2026-11-06 09-05.txt")
    #expect(Workspace.sessionFileName(title: "logs/prod: web", date: date) == "logs-prod- web 2026-11-06 09-05.txt")
}

@Test
func aSavedPasswordWaitsForItsOwnHostsPrompt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let broker = try AskpassBroker(directory: directory, helperPath: "/bin/true")
    let token = broker.issue("target-secret", for: ["herb@nas.local", "herb@192.0.2.5"])
    var asked: [String] = []
    let terminal: (String, Bool) -> String? = { prompt, _ in asked.append(prompt); return "typed" }
    // A ProxyJump bastion asking first is answered on the terminal, and the password stays for the target.
    #expect(HelperMode.askpass(prompt: "ops@bastion's password: ", token: token, socket: broker.socketPath, terminal: terminal) == "typed")
    #expect(HelperMode.askpass(prompt: "herb@192.0.2.5's password: ", token: token, socket: broker.socketPath, terminal: terminal) == "target-secret")
    #expect(asked == ["ops@bastion's password: "])

    // A client that connects and never writes doesn't hold up the next one for long.
    let stalled = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: broker.socketPath.utf8) }
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(stalled, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    defer { close(stalled) }
    let started = Date()
    let next = broker.issue("next")
    #expect(AskpassBroker.redeem(token: next, socket: broker.socketPath) == "next")
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test
func asRootFoldersOtherAccountsCanChangeAreNotEmptied() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at: shared.appendingPathComponent("inner"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: shared.appendingPathComponent("inner/file"))
    let transfer = SFTPTransfer(client: try localSFTP())
    // Not root's, so as root it's refused and everything stays.
    #expect(throws: (any Error).self) { try transfer.remove(shared.path, asRoot: true) }
    #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("inner/file").path))
    // With the user's own access it's deleted as before.
    try transfer.remove(shared.path)
    #expect(!FileManager.default.fileExists(atPath: shared.path))
}

@Test
func pipelinedTransfersKeepEveryByte() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    // An odd size, so the last chunk is short; ~1.3 MB keeps many requests in flight.
    var bytes = Data(count: 1_300_003)
    for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
    let original = root.appendingPathComponent("big.bin")
    try bytes.write(to: original)
    let transfer = SFTPTransfer(client: try localSFTP())
    try transfer.upload(original, to: root.appendingPathComponent("up.bin").path)
    try transfer.download(root.appendingPathComponent("up.bin").path, to: root.appendingPathComponent("down.bin"))
    try transfer.copy(root.appendingPathComponent("down.bin").path, to: root.appendingPathComponent("copy.bin").path)
    for name in ["up.bin", "down.bin", "copy.bin"] {
        #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes, "\(name)")
    }
    #expect(try transfer.readAll(original.path, limit: 2_000_000) == bytes)
    // Cancelling midway leaves the channel usable for the next request.
    var cancelled = SFTPTransfer(client: try localSFTP())
    var chunks = 0
    cancelled.isCancelled = { chunks += 1; return chunks > 3 }
    #expect(throws: (any Error).self) { try cancelled.download(original.path, to: root.appendingPathComponent("partial.bin")) }
    #expect(try cancelled.client.stat(original.path, follow: true).size == UInt64(bytes.count))
}

@Test
func aServerThatStopsAnsweringTimesOut() throws {
    let saved = SFTPClient.replyTimeout
    SFTPClient.replyTimeout = 1000
    defer { SFTPClient.replyTimeout = saved }
    // A fake server: answers the SFTP version handshake, then never replies again.
    let client = try SFTPClient(executable: "/bin/sh", arguments: ["-c", "printf '\\000\\000\\000\\005\\002\\000\\000\\000\\003'; cat >/dev/null"])
    let started = Date()
    #expect(throws: (any Error).self) { try client.stat("/", follow: true) }
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test
func hostCommandOutputIsCappedWhileItRuns() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "yes 0123456789 | head -c 3000000"]
    let target = HostTarget(endpoint: RemoteEndpoint(host: "local", username: "me"), password: nil, source: "test")
    let result = await MultiHostModel.execute(process, target: target)
    #expect(result.output.hasSuffix("… output truncated"))
    #expect(result.output.utf8.count < MultiHostModel.outputLimit + 100)
}

@Test
func tailcatProxyKeepsTheAddressOffTheCommandLineAndFailsCleanly() throws {
    let tailcat = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/tailcat/tailcat").path
    try #require(FileManager.default.isExecutableFile(atPath: tailcat))
    let started = Date()
    // An address no peer serves: the local SOCKS proxy starts, refuses the dial, and the helper exits with 1.
    #expect(TailcatProxy.run(tailcat: tailcat, address: "tcnotarealaddress", port: 22) == 1)
    #expect(Date().timeIntervalSince(started) < 30)
}

@Test
func sshEndsSoonAfterTheHostGoesAway() {
    // Both the app's logins and a typed ssh ask the server for a reply every 5 s and give up after 2 misses.
    let options = SSHControl.masterOptions.joined(separator: " ")
    #expect(options.contains("-o ServerAliveInterval=5") && options.contains("-o ServerAliveCountMax=2"))
    #expect(ShellIntegration.sshFunction.contains("-o ServerAliveInterval=5 -o ServerAliveCountMax=2 \"$@\""))
}

@Test @MainActor
func takeScreenshotPicturesTheWholeWindow() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    let shell = LocalShell()
    window.contentView = shell.view
    let bitmap = try #require(Workspace.windowImage(window))
    let frame = try #require(window.contentView?.superview)
    // The frame view, titlebar included, at the backing scale.
    #expect(bitmap.size == frame.bounds.size)
    #expect(bitmap.pixelsWide >= Int(window.frame.width) && bitmap.pixelsHigh >= Int(window.frame.height))
    #expect(bitmap.representation(using: .png, properties: [:]) != nil)
    // The terminal's own background is in the picture, not left transparent.
    let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
    #expect(middle.alphaComponent == 1)
}

@Test @MainActor
func exitInTheLastTabQuitsOnlyWhenNoOtherWindowIsOpen() {
    // `exit` in a window's last tab quits the app only when it was the last window; with another window
    // open it closes just its own window.
    let first = Workspace(restoring: nil), second = Workspace(restoring: nil)
    defer { [first, second].forEach { $0.tabs.forEach { $0.shells.forEach { $0.close() } } } }
    let windows = [first, second].map { _ in
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    }
    defer { windows.forEach { $0.orderOut(nil) } }
    first.window = windows[0]; second.window = windows[1]
    windows.forEach { $0.orderBack(nil) }
    #expect(!first.isLastWindow && !second.isLastWindow)
}

@Test @MainActor
func titleReturnsToThisMacWhenTheRemoteSessionEnds() {
    // The remote shell names the tab while connected; when the session ends (exit or a dropped link),
    // the tab shows this Mac's user@host again, not the remote title.
    let shell = LocalShell()
    let local = shell.legend.title
    shell.legend.setRemote(target: "admin@server", location: "/home/admin")
    shell.legend.setTerminalTitle(source: shell.view, title: "admin@server: ~")
    #expect(shell.legend.title == "admin@server")
    shell.legend.setRemote(target: nil)
    #expect(shell.legend.title == local)
    #expect(shell.legend.subtitle == "~")
}

@Test
func askpassLeavesOtherQuestionsToTheLinuxScriptWhenToldNotToUseTheTerminal() {
    // The Linux host script asks a new host's fingerprint question itself; the helper, run from inside the
    // Flatpak, must answer "no answer" at once instead of reaching for the terminal (where it would be stopped).
    let status = HelperMode.run(environment: ["HERBSTERMINAL_HELPER": "askpass", "HERBSTERMINAL_ASK_ON_TERMINAL": "no"],
                                arguments: ["herbs-terminal", "Are you sure you want to continue connecting (yes/no/[fingerprint])? "])
    #expect(status == 1)
}
