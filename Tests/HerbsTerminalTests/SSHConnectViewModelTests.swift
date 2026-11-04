import CryptoKit
import Foundation
import Testing
@testable import HerbsTerminal

@Suite("SSH Connect View Model Tests")
@MainActor
struct SSHConnectViewModelTests {

    private func createTestStore() throws -> (CredentialStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("vm_test_logins.sqlite3")
        let key = SymmetricKey(size: .bits256)
        let vault = CryptoVault(keyProvider: StaticKeyProvider(key: key))
        let store = try CredentialStore(databaseURL: dbURL, vault: vault)
        return (store, tempDir)
    }

    @Test
    func selectingSavedAccountPopulatesFields() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let saved = SSHLogin(host: "prod.example.com", port: 2222, username: "deploy", password: "saved_pass")
        try store.save(saved)

        let vm = SSHConnectViewModel(store: store)
        vm.select(login: saved)

        #expect(vm.host == "prod.example.com")
        #expect(vm.port == 2222)
        #expect(vm.username == "deploy")
        #expect(vm.password == "saved_pass")
    }

    @Test
    func connectValidatesAndOptionallySavesLogin() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = SSHConnectViewModel(store: store)
        vm.host = "staging.internal"
        vm.port = 22
        vm.username = "ci"
        vm.password = "staging_token"
        vm.saveToLogins = true

        let login = try vm.handleConnect()
        #expect(login.host == "staging.internal")
        #expect(login.username == "ci")

        // Should be persisted in store because saveToLogins was true
        #expect(store.list().contains { $0.id == login.id })
    }

    @Test
    func connectRejectsInvalidData() throws {
        let (store, tempDir) = try createTestStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = SSHConnectViewModel(store: store)
        vm.host = "" // invalid empty host
        vm.port = 22
        vm.username = "user"

        #expect(throws: (any Error).self) {
            try vm.handleConnect()
        }
    }
}
