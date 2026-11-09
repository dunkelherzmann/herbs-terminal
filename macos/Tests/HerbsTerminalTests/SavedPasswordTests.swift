import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Saved Passwords")
@MainActor
struct SavedPasswordTests {
    private func open(_ url: URL) throws -> CredentialStore { try CredentialStore(databaseURL: url, iterations: 1_000) }

    private func scratchDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("logins.sqlite3")
    }

    private func fileContains(_ url: URL, _ text: String) throws -> Bool {
        try Data(contentsOf: url).range(of: Data(text.utf8)) != nil
    }

    @Test
    func passwordsAreAVaultOfTheirOwnUnderTheAdministratorPassword() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        let sudo = SavedPassword(name: "nas sudo", password: "s3cret-sudo-pw", description: "root on the NAS")
        #expect(throws: StoreError.self) { try store.savePassword(sudo) } // No protection chosen yet.
        try store.setAdminPassword("admin-password-1")
        try store.savePassword(sudo)
        try store.save(SSHLogin(host: "nas", port: 22, username: "me", password: "login-pw"))
        #expect(store.passwords == [sudo])
        #expect(store.logins.count == 1)
        #expect(try !fileContains(url, "s3cret-sudo-pw"))

        // Locked at the next start; the one Administrator Password unlocks both vaults.
        let reopened = try open(url)
        #expect(reopened.isLocked && reopened.passwords.isEmpty && reopened.lockedPasswordCount == 1)
        try reopened.unlock("admin-password-1")
        #expect(reopened.passwords == [sudo])
        #expect(reopened.logins.count == 1)
    }

    @Test
    func changingAndRemovingTheAdministratorPasswordReencryptsPasswords() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        try store.setAdminPassword("first-password")
        let saved = SavedPassword(name: "db", password: "db-pw-123")
        try store.savePassword(saved)
        try store.setAdminPassword("second-password", current: "first-password")
        let reopened = try open(url)
        #expect(throws: StoreError.self) { try reopened.unlock("first-password") }
        try reopened.unlock("second-password")
        #expect(reopened.passwords == [saved])

        try reopened.removeAdminPassword(current: "second-password")
        let plain = try open(url)
        #expect(plain.passwords == [saved])
        #expect(plain.plainTextPasswordIDs == [saved.id])
    }

    @Test
    func namesAreUniqueIgnoringCaseAndEditsReplaceTheOldEntry() throws {
        let url = try scratchDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try open(url)
        try store.choosePlainText()
        try store.savePassword(SavedPassword(name: "Web", password: "one"))
        #expect(throws: StoreError.self) { try store.savePassword(SavedPassword(name: "web", password: "two")) }
        #expect(throws: StoreError.self) { try store.savePassword(SavedPassword(name: "  ", password: "x")) }
        #expect(throws: StoreError.self) { try store.savePassword(SavedPassword(name: "empty", password: "")) }
        try store.savePassword(SavedPassword(name: "Website", password: "three", description: "renamed"), replacing: "web")
        #expect(store.passwords.map(\.name) == ["Website"])
        #expect(store.passwords.first?.password == "three")
        try store.deletePassword(id: "website")
        #expect(store.passwords.isEmpty)
    }
}
