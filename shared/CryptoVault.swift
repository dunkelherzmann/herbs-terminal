import CryptoKit
import Foundation

struct VaultError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct EncryptedPayload: Equatable, Sendable {
    var ciphertext: Data
    var nonce: Data
    var tag: Data
}

protocol KeyProvider: Sendable {
    func encryptionKey() throws -> SymmetricKey
}

struct StaticKeyProvider: KeyProvider {
    let key: SymmetricKey
    func encryptionKey() throws -> SymmetricKey { key }
}

/// AES-GCM sealing with a key supplied by the caller (the login store derives it from the Administrator Password).
struct CryptoVault: Sendable {
    let keyProvider: any KeyProvider

    init(keyProvider: any KeyProvider) {
        self.keyProvider = keyProvider
    }

    func encrypt(_ plaintext: String) throws -> EncryptedPayload {
        let key = try keyProvider.encryptionKey()
        let data = Data(plaintext.utf8)
        let sealed = try AES.GCM.seal(data, using: key)
        return EncryptedPayload(
            ciphertext: sealed.ciphertext,
            nonce: Data(sealed.nonce),
            tag: sealed.tag
        )
    }

    func decrypt(_ payload: EncryptedPayload) throws -> String {
        let key = try keyProvider.encryptionKey()
        let nonce = try AES.GCM.Nonce(data: payload.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
        let decryptedData = try AES.GCM.open(box, using: key)
        guard let string = String(data: decryptedData, encoding: .utf8) else {
            throw VaultError("Decrypted secret is not valid UTF-8 string.")
        }
        return string
    }
}
