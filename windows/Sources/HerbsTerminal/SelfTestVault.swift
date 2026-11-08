import CommonCrypto
import Foundation

extension SelfTest {
    /// The login vault on a throwaway database: PBKDF2 against a published vector, then an Administrator Password,
    /// a saved login, and the same login read back after reopening and unlocking.
    static func vaultChecks() {

        // PBKDF2-HMAC-SHA256, P = "password", S = "salt", c = 1, dkLen = 32 (RFC 7914 §11 style vector).
        let key = try? CredentialStore.deriveKey(password: "password", salt: Data("salt".utf8), iterations: 1)
        let hex = key?.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        check("PBKDF2-SHA256 matches the published vector",
              hex == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herbs-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("logins.sqlite3")
        let login = SSHLogin(host: "server.example", port: 22, username: "admin", password: "correct horse")
        do {
            let store = try CredentialStore(databaseURL: database, iterations: 1000)
            try store.setAdminPassword("vault-password")
            try store.save(login)
            check("Login vault saves an encrypted login", store.get(id: login.id)?.password == "correct horse")

            let reopened = try CredentialStore(databaseURL: database, iterations: 1000)
            check("Reopened vault starts locked", reopened.get(id: login.id)?.password != "correct horse")
            check("Wrong Administrator Password is refused", !reopened.verify("wrong"))
            try reopened.unlock("vault-password")
            check("Unlocked vault reveals the login", reopened.get(id: login.id)?.password == "correct horse")
        } catch {
            check("Login vault works (\(error.localizedDescription))", false)
        }
    }
}
