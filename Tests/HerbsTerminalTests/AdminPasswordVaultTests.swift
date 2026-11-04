import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import HerbsTerminal

@Suite("Administrator Password Vault Tests")
@MainActor
struct AdminPasswordVaultTests {
    /// Low iteration count keeps the suite fast; the app uses CredentialStore.defaultIterations.
    private func open(_ url: URL) throws -> CredentialStore { try CredentialStore(databaseURL: url, iterations: 1_000) }

    private func scratchDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("logins.sqlite3")
    }

    private func fileContains(_ url: URL, _ text: String) throws -> Bool {
        try Data(contentsOf: url).range(of: Data(text.utf8)) != nil
    }

    @Test
    func nothingIsSavedUntilProtectionIsChosenThenPlainTextIsReadable() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        #expect(store.protection == .unset)
        let login = SSHLogin(host: "nas.local", port: 22, username: "admin", password: "plain,pa\"ss")
        #expect(throws: StoreError.self) { try store.save(login) }

        try store.choosePlainText()
        try store.save(login)
        let reopened = try open(url)
        #expect(reopened.protection == .plainText)
        #expect(reopened.logins == [login])
        #expect(!reopened.isLocked)
        #expect(try reopened.reveal(try reopened.protect("tc-address")) == "tc-address")
    }

    @Test
    func creatingTheAdminPasswordEncryptsExistingLoginsAndLocksAtNextLaunch() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        try store.choosePlainText()
        try store.save(SSHLogin(host: "a.example", port: 22, username: "u", password: "first-secret"))
        #expect(try fileContains(url, "first-secret"))

        #expect(throws: StoreError.self) { try store.setAdminPassword("short") }
        try store.setAdminPassword("correct horse")
        try store.save(SSHLogin(host: "b.example", port: 2222, username: "u", password: "second-secret"))
        #expect(store.logins.count == 2)
        // The database holds neither password nor the Administrator Password itself.
        let reopened = try open(url)
        let leaksFirst = try fileContains(url, "first-secret")
        let leaksSecond = try fileContains(url, "second-secret")
        let leaksAdmin = try fileContains(url, "correct horse")
        #expect(!leaksFirst && !leaksSecond && !leaksAdmin)

        // A new session starts locked; a wrong password changes nothing.
        #expect(reopened.protection == .adminPassword && reopened.isLocked)
        #expect(reopened.logins.isEmpty && reopened.lockedCount == 2)
        #expect(throws: StoreError.self) { try reopened.unlock("wrong password") }
        #expect(reopened.isLocked)
        #expect(throws: StoreError.self) { try reopened.save(SSHLogin(host: "c", port: 22, username: "u", password: "x")) }
        try reopened.unlock("correct horse")
        #expect(reopened.logins.map(\.password).sorted() == ["first-secret", "second-secret"])
        #expect(reopened.verify("correct horse") && !reopened.verify("nope"))

        let address = try reopened.protect("tc1-bearer")
        #expect(address.range(of: Data("tc1-bearer".utf8)) == nil)
        #expect(try reopened.reveal(address) == "tc1-bearer")
        reopened.lock()
        #expect(reopened.isLocked && reopened.logins.isEmpty)
        #expect(throws: StoreError.self) { try reopened.reveal(address) }
    }

    @Test
    func modifyingTheAdminPasswordReencryptsEverything() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        try store.setAdminPassword("old password")
        try store.save(SSHLogin(host: "h", port: 22, username: "u", password: "kept"))
        #expect(throws: StoreError.self) { try store.setAdminPassword("new password", current: "not it") }
        try store.setAdminPassword("new password", current: "old password")

        let reopened = try open(url)
        #expect(throws: StoreError.self) { try reopened.unlock("old password") }
        try reopened.unlock("new password")
        #expect(reopened.logins.first?.password == "kept")
    }

    @Test
    func loginsFromKeychainEraBuildsCanBeRecoveredOrDiscarded() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // An earlier build's row: AES-GCM with a key that lived in the Keychain, and no scheme column.
        let oldKey = SymmetricKey(size: .bits256)
        let payload = try CryptoVault(keyProvider: StaticKeyProvider(key: oldKey)).encrypt("legacy-secret")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE logins (host TEXT NOT NULL, port INTEGER NOT NULL, username TEXT NOT NULL, ciphertext BLOB NOT NULL, nonce BLOB NOT NULL, tag BLOB NOT NULL, PRIMARY KEY (host, port, username));", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO logins VALUES ('old.host', 22, 'me', ?, ?, ?);", -1, &stmt, nil)
        for (index, data) in [payload.ciphertext, payload.nonce, payload.tag].enumerated() {
            // Transient: SQLite copies the bytes, which outlive this closure only that way.
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, Int32(index + 1), $0.baseAddress, Int32(data.count),
                                                         unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        let store = try open(url)
        #expect(store.legacyCount == 1 && store.logins.isEmpty)
        #expect(throws: StoreError.self) { _ = try store.recoverLegacy(keyProvider: StaticKeyProvider(key: oldKey)) }
        try store.setAdminPassword("admin password")
        // A refused or wrong key leaves the row untouched.
        #expect(throws: (any Error).self) { _ = try store.recoverLegacy(keyProvider: StaticKeyProvider(key: SymmetricKey(size: .bits256))) }
        #expect(store.legacyCount == 1)
        #expect(try store.recoverLegacy(keyProvider: StaticKeyProvider(key: oldKey)) == 1)
        #expect(store.legacyCount == 0 && store.logins.first?.password == "legacy-secret")

        try store.discardLegacy()
        #expect(store.legacyCount == 0 && store.logins.count == 1)
    }
}
