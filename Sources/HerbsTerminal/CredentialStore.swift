import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

enum ConflictPolicy: Sendable {
    case overwrite
    case skip
    case fail
}

struct ImportSummary: Equatable, Sendable {
    let added: Int
    let updated: Int
    let skipped: Int
}

struct StoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// How saved logins (and Tailcat addresses) are protected. Nothing is kept in system key stores: with an
/// Administrator Password, secrets are AES-GCM encrypted with a key derived from it (PBKDF2-SHA256, random
/// salt); the password itself is never stored. Without one they are kept as plain text, after a warning.
enum LoginProtection: String {
    /// Not chosen yet: the first-use explanation is still due.
    case unset
    case plainText = "plain"
    case adminPassword = "password"
}

@MainActor
final class CredentialStore: ObservableObject {
    static let opened = Result { try CredentialStore() }
    static var shared: CredentialStore? { try? opened.get() }
    /// Stands in when the login database can't be opened: kept in memory only, never written anywhere.
    static func unavailable() -> CredentialStore {
        try! CredentialStore(databaseURL: URL(fileURLWithPath: ":memory:"), vault: CryptoVault(keyProvider: StaticKeyProvider(key: .init(size: .bits256))))
    }
    /// Only for a database that can't be opened at all; locked logins are reported by `isLocked`.
    static var unavailableReason: String? {
        if case .failure(let error) = opened { error.localizedDescription } else { nil }
    }

    static let defaultIterations = 600_000

    private var db: OpaquePointer?
    /// The derived key while unlocked (or a fixed key injected by tests).
    private var vault: CryptoVault?
    private let iterations: Int
    @Published private(set) var logins: [SSHLogin] = []
    @Published private(set) var protection: LoginProtection = .unset
    /// Rows encrypted with the Administrator Password while it hasn't been entered this session.
    @Published private(set) var lockedCount = 0
    /// Readable logins stored as plain text rather than encrypted.
    @Published private(set) var plainTextIDs: Set<SSHLogin.ID> = []
    /// Rows from earlier builds, encrypted with a key this app no longer holds; they can only be discarded.
    @Published private(set) var legacyCount = 0

    var isLocked: Bool { protection == .adminPassword && vault == nil }

    /// `vault` fixes the encryption key (tests); otherwise protection follows the Administrator Password.
    init(databaseURL: URL? = nil, vault: CryptoVault? = nil, iterations: Int = CredentialStore.defaultIterations) throws {
        self.vault = vault
        self.iterations = iterations
        let fileURL: URL
        if let databaseURL {
            fileURL = databaseURL
        } else {
            try FileManager.default.createDirectory(at: AppFolders.support(), withIntermediateDirectories: true)
            fileURL = AppFolders.loginDatabase()
        }

        var dbPointer: OpaquePointer?
        // SQLite's in-memory database is named by the bare string; a file URL would make it a real file.
        let path = fileURL.lastPathComponent == ":memory:" ? ":memory:" : fileURL.path
        if sqlite3_open_v2(path, &dbPointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let errorMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw StoreError("Unable to open credentials database: \(errorMsg)")
        }
        self.db = dbPointer
        if path != ":memory:" { chmod(path, 0o600) }

        try createTable()
        if vault != nil {
            protection = .adminPassword
        } else {
            protection = metaString("protection").flatMap(LoginProtection.init(rawValue:)) ?? .unset
        }
        try reload()
    }

    isolated deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    private func createTable() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS logins (
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            ciphertext BLOB NOT NULL,
            nonce BLOB NOT NULL,
            tag BLOB NOT NULL,
            PRIMARY KEY (host, port, username)
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        """)
        // Rows written before the app had its own vault used a key it no longer holds.
        if !columnExists("scheme") {
            try execute(sql: "ALTER TABLE logins ADD COLUMN scheme TEXT NOT NULL DEFAULT 'legacy';")
        }
        try execute(sql: "UPDATE logins SET scheme = 'legacy' WHERE scheme = 'keychain';")
    }

    private func execute(sql: String) throws {
        guard let db else { throw StoreError("Database is not open.") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQL execution failed"
            sqlite3_free(errorPointer)
            throw StoreError(message)
        }
    }

    // MARK: Administrator Password

    /// The scheme new rows are written with.
    private var writeScheme: String { protection == .adminPassword ? "admin" : "plain" }

    /// Keeps logins as plain text inside Herb's Terminal, after the user has read why that is a risk.
    func choosePlainText() throws {
        guard protection != .adminPassword else { throw StoreError("An Administrator Password is already set.") }
        try setMeta("protection", Data(LoginProtection.plainText.rawValue.utf8))
        protection = .plainText
    }

    /// Creates the Administrator Password, or changes it when `current` is the existing one. Every readable
    /// login is re-encrypted with the new key in one transaction, so a failure leaves the old state intact.
    func setAdminPassword(_ new: String, current: String? = nil) throws {
        guard new.count >= 8 else { throw StoreError("Use at least 8 characters for the Administrator Password.") }
        if protection == .adminPassword {
            guard let current else { throw StoreError("Enter the current Administrator Password.") }
            try unlock(current)
        }
        let salt = Self.randomBytes(16)
        let key = try Self.deriveKey(password: new, salt: salt, iterations: iterations)
        let newVault = CryptoVault(keyProvider: StaticKeyProvider(key: key))
        let check = try Self.combined(newVault.encrypt(Self.checkPhrase))
        let readable = logins
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for login in readable { try write(login, scheme: "admin", vault: newVault) }
            try setMeta("salt", salt)
            try setMeta("iterations", Data(String(iterations).utf8))
            try setMeta("check", check)
            try setMeta("protection", Data(LoginProtection.adminPassword.rawValue.utf8))
            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
        vault = newVault
        protection = .adminPassword
        try reload()
    }

    /// Removes the Administrator Password after checking `current`: every login is stored as plain text again,
    /// in one transaction, and the key material is deleted.
    func removeAdminPassword(current: String) throws {
        guard protection == .adminPassword else { return }
        try unlock(current)
        let readable = logins
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for login in readable { try write(login, scheme: "plain", vault: nil) }
            try setMeta("protection", Data(LoginProtection.plainText.rawValue.utf8))
            try execute(sql: "DELETE FROM meta WHERE key IN ('salt', 'iterations', 'check');")
            try execute(sql: "COMMIT;")
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
        vault = nil
        protection = .plainText
        try reload()
    }

    /// Unlocks saved logins for this session. A wrong password changes nothing.
    func unlock(_ password: String) throws {
        guard protection == .adminPassword else { return }
        guard let salt = metaData("salt"), let check = metaData("check"),
              let rounds = metaString("iterations").flatMap(Int.init) else {
            throw StoreError("The Administrator Password settings are missing.")
        }
        let candidate = CryptoVault(keyProvider: StaticKeyProvider(key: try Self.deriveKey(password: password, salt: salt, iterations: rounds)))
        guard let payload = Self.split(check), let opened = try? candidate.decrypt(payload), Self.isCheckValue(opened) else {
            throw StoreError("That Administrator Password is not correct.")
        }
        // Check values written by earlier builds are replaced with the current one.
        if opened != Self.checkPhrase { try? setMeta("check", Self.combined(candidate.encrypt(Self.checkPhrase))) }
        vault = candidate
        try reload()
    }

    /// Forgets the key until the Administrator Password is entered again.
    func lock() {
        guard protection == .adminPassword, metaData("salt") != nil else { return }
        vault = nil
        try? reload()
    }

    /// Whether `password` is the Administrator Password, without changing the lock state.
    func verify(_ password: String) -> Bool {
        guard let salt = metaData("salt"), let check = metaData("check"),
              let rounds = metaString("iterations").flatMap(Int.init),
              let key = try? Self.deriveKey(password: password, salt: salt, iterations: rounds),
              let payload = Self.split(check) else { return false }
        return (try? CryptoVault(keyProvider: StaticKeyProvider(key: key)).decrypt(payload)).map(Self.isCheckValue) ?? false
    }

    /// Protects a secret kept elsewhere in Herb's Terminal (a Tailcat address) the same way as login passwords.
    func protect(_ secret: String) throws -> Data {
        switch protection {
        case .adminPassword:
            guard let vault else { throw StoreError("Unlock saved logins with the Administrator Password first.") }
            return Data([1]) + Self.combined(try vault.encrypt(secret))
        case .plainText, .unset:
            return Data([0]) + Data(secret.utf8)
        }
    }

    func reveal(_ data: Data) throws -> String {
        guard let marker = data.first else { throw StoreError("Empty secret.") }
        let body = Data(data.dropFirst())
        if marker == 0 { return String(decoding: body, as: UTF8.self) }
        guard let vault else { throw StoreError("Unlock saved logins with the Administrator Password first.") }
        guard let payload = Self.split(body) else { throw StoreError("Damaged secret.") }
        return try vault.decrypt(payload)
    }

    // MARK: Logins from earlier builds

    /// Permanently deletes logins from earlier builds that can no longer be read.
    func discardLegacy() throws {
        try execute(sql: "DELETE FROM logins WHERE scheme = 'legacy';")
        try reload()
    }

    // MARK: Rows

    private struct Row {
        let host: String, port: Int, username: String, scheme: String
        let payload: EncryptedPayload
    }

    private func readRows() throws -> [Row] {
        guard let db else { throw StoreError("Database is not open.") }
        let query = "SELECT host, port, username, ciphertext, nonce, tag, scheme FROM logins ORDER BY host, username;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError("Failed to prepare query: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        func blob(_ column: Int32) -> Data {
            let length = sqlite3_column_bytes(stmt, column)
            return sqlite3_column_blob(stmt, column).map { Data(bytes: $0, count: Int(length)) } ?? Data()
        }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(host: String(cString: sqlite3_column_text(stmt, 0)), port: Int(sqlite3_column_int(stmt, 1)),
                            username: String(cString: sqlite3_column_text(stmt, 2)),
                            scheme: String(cString: sqlite3_column_text(stmt, 6)),
                            payload: EncryptedPayload(ciphertext: blob(3), nonce: blob(4), tag: blob(5))))
        }
        return rows
    }

    /// Loads every login this session can read; the rest are counted, never dropped.
    func reload() throws {
        var readable: [SSHLogin] = [], locked = 0, legacy = 0, plain: Set<SSHLogin.ID> = []
        for row in try readRows() {
            switch row.scheme {
            case "plain":
                let login = SSHLogin(host: row.host, port: row.port, username: row.username,
                                     password: String(decoding: row.payload.ciphertext, as: UTF8.self))
                readable.append(login)
                plain.insert(login.id)
            case "admin":
                if let vault, let password = try? vault.decrypt(row.payload) {
                    readable.append(SSHLogin(host: row.host, port: row.port, username: row.username, password: password))
                } else {
                    locked += 1
                }
            default:
                legacy += 1
            }
        }
        logins = readable
        plainTextIDs = plain
        lockedCount = locked
        legacyCount = legacy
    }

    private func write(_ login: SSHLogin, scheme: String, vault: CryptoVault?) throws {
        guard let db else { throw StoreError("Database is not open.") }
        let payload: EncryptedPayload
        if scheme == "admin" {
            guard let vault else { throw StoreError("Unlock saved logins with the Administrator Password first.") }
            payload = try vault.encrypt(login.password)
        } else {
            payload = EncryptedPayload(ciphertext: Data(login.password.utf8), nonce: Data(), tag: Data())
        }
        // Host names ignore case, as `SSHLogin.id` does; the newest spelling replaces any other.
        var clear: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM logins WHERE LOWER(host) = LOWER(?1) AND host <> ?1 AND port = ?2 AND username = ?3;", -1, &clear, nil) == SQLITE_OK else {
            throw StoreError("Failed to prepare save: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(clear) }
        sqlite3_bind_text(clear, 1, (login.host as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(clear, 2, Int32(login.port))
        sqlite3_bind_text(clear, 3, (login.username as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(clear) == SQLITE_DONE else {
            throw StoreError("Failed to save login: \(String(cString: sqlite3_errmsg(db)))")
        }
        let sql = """
        INSERT INTO logins (host, port, username, ciphertext, nonce, tag, scheme)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(host, port, username) DO UPDATE SET
            ciphertext = excluded.ciphertext, nonce = excluded.nonce, tag = excluded.tag, scheme = excluded.scheme;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError("Failed to prepare save: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (login.host as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(login.port))
        sqlite3_bind_text(stmt, 3, (login.username as NSString).utf8String, -1, SQLITE_TRANSIENT)
        for (index, data) in [payload.ciphertext, payload.nonce, payload.tag].enumerated() {
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, Int32(4 + index), $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(data.count), SQLITE_TRANSIENT) }
        }
        sqlite3_bind_text(stmt, 7, (scheme as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError("Failed to save login: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: Meta values

    private func setMeta(_ key: String, _ value: Data) throws {
        guard let db else { throw StoreError("Database is not open.") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError("Failed to prepare settings update.")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError("Failed to save settings.") }
    }

    private func metaData(_ key: String) -> Data? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let length = sqlite3_column_bytes(stmt, 0)
        return sqlite3_column_blob(stmt, 0).map { Data(bytes: $0, count: Int(length)) } ?? Data()
    }

    private func metaString(_ key: String) -> String? { metaData(key).map { String(decoding: $0, as: UTF8.self) } }

    private func columnExists(_ name: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(logins);", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == name { return true }
        }
        return false
    }

    // MARK: Crypto helpers

    private static let checkPhrase = "herbsterminal-admin-password-check-v1"

    /// AES-GCM only decrypts with the right key, so a check value that opens proves the password; the
    /// prefix has changed between builds, the suffix hasn't.
    static func isCheckValue(_ text: String) -> Bool { text.hasSuffix("-admin-password-check-v1") }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count)
        }
        guard status == kCCSuccess else { throw StoreError("Couldn't derive the encryption key (status \(status)).") }
        return SymmetricKey(data: key)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// nonce (12) + tag (16) + ciphertext, for values kept as one blob.
    private static func combined(_ payload: EncryptedPayload) -> Data { payload.nonce + payload.tag + payload.ciphertext }

    private static func split(_ data: Data) -> EncryptedPayload? {
        guard data.count >= 28 else { return nil }
        let bytes = Array(data)
        return EncryptedPayload(ciphertext: Data(bytes[28...]), nonce: Data(bytes[0..<12]), tag: Data(bytes[12..<28]))
    }

    func list() -> [SSHLogin] {
        return logins
    }

    func get(id: SSHLogin.ID) -> SSHLogin? {
        return logins.first { $0.id == id }
    }

    func save(_ login: SSHLogin) throws {
        try login.validate()
        guard protection != .unset else { throw StoreError("Choose how to protect saved logins first: create an Administrator Password or allow plain text.") }
        try write(login, scheme: writeScheme, vault: vault)
        try reload()
    }

    func delete(id: SSHLogin.ID) throws {
        guard let db else { throw StoreError("Database is not open.") }
        let sql = "DELETE FROM logins WHERE LOWER(host) = LOWER(?) AND port = ? AND username = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StoreError("Failed to prepare delete: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id.host as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(id.port))
        sqlite3_bind_text(stmt, 3, (id.username as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StoreError("Failed to delete login: \(msg)")
        }

        try reload()
    }

    func importCSV(_ data: Data, policy: ConflictPolicy = .overwrite) throws -> ImportSummary {
        let records = try LoginCSV.decode(data)
        guard db != nil else { throw StoreError("Database is not open.") }

        try execute(sql: "BEGIN TRANSACTION;")
        var added = 0
        var updated = 0
        var skipped = 0

        do {
            for record in records {
                let existing = get(id: record.id)
                if let _ = existing {
                    switch policy {
                    case .overwrite:
                        try save(record)
                        updated += 1
                    case .skip:
                        skipped += 1
                    case .fail:
                        throw StoreError("Conflict: record already exists for \(record.label).")
                    }
                } else {
                    try save(record)
                    added += 1
                }
            }
            try execute(sql: "COMMIT;")
            try reload()
            return ImportSummary(added: added, updated: updated, skipped: skipped)
        } catch {
            try? execute(sql: "ROLLBACK;")
            try? reload()
            throw error
        }
    }

    /// The logins as CSV; `only` limits it to those logins.
    func exportCSV(only ids: Set<SSHLogin.ID>? = nil) throws -> Data {
        return LoginCSV.encode(ids.map { ids in logins.filter { ids.contains($0.id) } } ?? logins)
    }
}
