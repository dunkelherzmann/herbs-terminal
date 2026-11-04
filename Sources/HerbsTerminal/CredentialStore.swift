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

@MainActor
final class CredentialStore: ObservableObject {
    static let shared = try? CredentialStore()

    private var db: OpaquePointer?
    private let vault: CryptoVault
    @Published private(set) var logins: [SSHLogin] = []

    init(databaseURL: URL? = nil, vault: CryptoVault = CryptoVault()) throws {
        self.vault = vault
        let fileURL: URL
        if let databaseURL {
            fileURL = databaseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("HerbsTerminal", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            fileURL = appSupport.appendingPathComponent("logins.sqlite3")
        }

        var dbPointer: OpaquePointer?
        if sqlite3_open_v2(fileURL.path, &dbPointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let errorMsg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw StoreError("Unable to open credentials database: \(errorMsg)")
        }
        self.db = dbPointer

        try createTable()
        try reload()
    }

    isolated deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    private func createTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS logins (
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            username TEXT NOT NULL,
            ciphertext BLOB NOT NULL,
            nonce BLOB NOT NULL,
            tag BLOB NOT NULL,
            PRIMARY KEY (host, port, username)
        );
        """
        try execute(sql: sql)
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

    func reload() throws {
        guard let db else { throw StoreError("Database is not open.") }
        let query = "SELECT host, port, username, ciphertext, nonce, tag FROM logins ORDER BY host, username;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StoreError("Failed to prepare query: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var results: [SSHLogin] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(stmt, 0))
            let port = Int(sqlite3_column_int(stmt, 1))
            let username = String(cString: sqlite3_column_text(stmt, 2))

            let cipherLen = sqlite3_column_bytes(stmt, 3)
            let cipherPtr = sqlite3_column_blob(stmt, 3)
            let ciphertext = cipherPtr.map { Data(bytes: $0, count: Int(cipherLen)) } ?? Data()

            let nonceLen = sqlite3_column_bytes(stmt, 4)
            let noncePtr = sqlite3_column_blob(stmt, 4)
            let nonce = noncePtr.map { Data(bytes: $0, count: Int(nonceLen)) } ?? Data()

            let tagLen = sqlite3_column_bytes(stmt, 5)
            let tagPtr = sqlite3_column_blob(stmt, 5)
            let tag = tagPtr.map { Data(bytes: $0, count: Int(tagLen)) } ?? Data()

            let payload = EncryptedPayload(ciphertext: ciphertext, nonce: nonce, tag: tag)
            let password = try vault.decrypt(payload)
            results.append(SSHLogin(host: host, port: port, username: username, password: password))
        }

        self.logins = results
    }

    func list() -> [SSHLogin] {
        return logins
    }

    func get(id: SSHLogin.ID) -> SSHLogin? {
        return logins.first { $0.id == id }
    }

    func save(_ login: SSHLogin) throws {
        try login.validate()
        guard let db else { throw StoreError("Database is not open.") }

        let payload = try vault.encrypt(login.password)
        let sql = """
        INSERT INTO logins (host, port, username, ciphertext, nonce, tag)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(host, port, username) DO UPDATE SET
            ciphertext = excluded.ciphertext,
            nonce = excluded.nonce,
            tag = excluded.tag;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StoreError("Failed to prepare save: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (login.host as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(login.port))
        sqlite3_bind_text(stmt, 3, (login.username as NSString).utf8String, -1, SQLITE_TRANSIENT)

        _ = payload.ciphertext.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(payload.ciphertext.count), SQLITE_TRANSIENT)
        }
        _ = payload.nonce.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(payload.nonce.count), SQLITE_TRANSIENT)
        }
        _ = payload.tag.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(payload.tag.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StoreError("Failed to save login: \(msg)")
        }

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

    func exportCSV() throws -> Data {
        return LoginCSV.encode(logins)
    }
}
