import CryptoKit
import Foundation
import Security

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

struct KeychainKeyProvider: KeyProvider {
    let service: String
    let account: String

    init(service: String = "org.herbsterminal.keychain", account: String = "master-credential-key") {
        self.service = service
        self.account = account
    }

    func encryptionKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        } else if status == errSecItemNotFound {
            let newKey = SymmetricKey(size: .bits256)
            let keyData = newKey.withUnsafeBytes { Data($0) }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VaultError("Failed to store master encryption key in Keychain (status \(addStatus)).")
            }
            return newKey
        } else {
            throw VaultError("Failed to access Keychain for master encryption key (status \(status)).")
        }
    }
}

struct CryptoVault: Sendable {
    let keyProvider: any KeyProvider

    init(keyProvider: any KeyProvider = KeychainKeyProvider()) {
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
