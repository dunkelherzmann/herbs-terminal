import CryptoKit
import Foundation
import Testing
@testable import HerbsTerminal

@Suite("SQLite Credential Store Tests")
@MainActor
struct CredentialStoreTests {

    private func createTestStore() throws -> (CredentialStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_logins.sqlite3")
        let key = SymmetricKey(size: .bits256)
        let vault = CryptoVault(keyProvider: StaticKeyProvider(key: key))
        let store = try CredentialStore(databaseURL: dbURL, vault: vault)
        return (store, tempDir)
    }

    @Test
    func saveAndRetrieveMultipleLogins() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let login1 = SSHLogin(host: "server1.example.com", port: 22, username: "admin", password: "p1,with,comma")
        let login2 = SSHLogin(host: "server1.example.com", port: 22, username: "root", password: "p2\"with\"quotes")
        let login3 = SSHLogin(host: "192.0.2.100", port: 2222, username: "deploy", password: "complex\npassword")

        try store.save(login1)
        try store.save(login2)
        try store.save(login3)

        let retrieved = store.list()
        #expect(retrieved.count == 3)

        let loaded1 = try #require(store.get(id: login1.id))
        #expect(loaded1.password == login1.password)

        let loaded2 = try #require(store.get(id: login2.id))
        #expect(loaded2.password == login2.password)

        let loaded3 = try #require(store.get(id: login3.id))
        #expect(loaded3.password == login3.password)
    }

    @Test
    func deleteLoginRemovesRecord() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let login = SSHLogin(host: "bastion.corp", port: 22, username: "ops", password: "secret_password")
        try store.save(login)
        #expect(store.list().count == 1)

        try store.delete(id: login.id)
        #expect(store.list().isEmpty)
        #expect(store.get(id: login.id) == nil)
    }

    @Test
    func csvRoundTripAndConflictHandling() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = [
            SSHLogin(host: "alpha.host", port: 22, username: "user1", password: "pass1,\"quoted\""),
            SSHLogin(host: "beta.host", port: 2200, username: "user2", password: "pass2,commas")
        ]
        for l in original { try store.save(l) }

        let exported = try store.exportCSV()
        #expect(!exported.isEmpty)

        // Fresh store importing exported CSV
        let (store2, tempDir2) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        let summary = try store2.importCSV(exported, policy: .overwrite)
        #expect(summary.added == 2)
        #expect(summary.updated == 0)
        #expect(summary.skipped == 0)

        let imported = store2.list()
        #expect(imported.count == 2)
        #expect(imported.contains { $0.username == "user1" && $0.password == "pass1,\"quoted\"" })
        #expect(imported.contains { $0.username == "user2" && $0.password == "pass2,commas" })
    }

    @Test
    func rejectedCsvPreservesPreviousStoreTransactionally() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existing = SSHLogin(host: "critical.prod", port: 22, username: "sysadmin", password: "do_not_lose_me")
        try store.save(existing)

        // Malformed CSV (missing header or invalid port in row 2)
        let malformedCsv = """
        host,port,username,password
        valid.host,22,alice,secret1
        invalid.host,NOT_A_PORT,bob,secret2
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try store.importCSV(malformedCsv, policy: .overwrite)
        }

        // Store must still have only the existing login, not partially applied records
        let list = store.list()
        #expect(list.count == 1)
        #expect(list.first?.host == "critical.prod")
    }
}
