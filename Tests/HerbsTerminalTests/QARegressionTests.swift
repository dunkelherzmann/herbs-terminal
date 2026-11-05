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
