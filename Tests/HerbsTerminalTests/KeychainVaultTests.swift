import CryptoKit
import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Keychain & Cryptographic Vault Tests")
struct KeychainVaultTests {

    @Test
    func encryptAndDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let provider = StaticKeyProvider(key: key)
        let vault = CryptoVault(keyProvider: provider)

        let testPasswords = [
            "simplepassword",
            "password,with,commas",
            "password\"with\"quotes",
            "complex!@#$%^&*()_+{}:\"<>?[];',./`~",
            "Unicode🔒🔑🚀With\nLines\r\nAnd\tTabs"
        ]

        for secret in testPasswords {
            let encrypted = try vault.encrypt(secret)
            #expect(!encrypted.ciphertext.isEmpty)
            #expect(encrypted.nonce.count == 12)
            #expect(encrypted.tag.count == 16)

            let decrypted = try vault.decrypt(encrypted)
            #expect(decrypted == secret)
        }
    }

    @Test
    func tamperedCiphertextFailsDecryption() throws {
        let key = SymmetricKey(size: .bits256)
        let provider = StaticKeyProvider(key: key)
        let vault = CryptoVault(keyProvider: provider)

        var encrypted = try vault.encrypt("sensitive_information")
        var bytes = Array(encrypted.ciphertext)
        if !bytes.isEmpty {
            bytes[0] ^= 0xFF
            encrypted.ciphertext = Data(bytes)
        }

        #expect(throws: (any Error).self) {
            try vault.decrypt(encrypted)
        }
    }

    @Test
    func differentKeyFailsDecryption() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)

        let vault1 = CryptoVault(keyProvider: StaticKeyProvider(key: key1))
        let vault2 = CryptoVault(keyProvider: StaticKeyProvider(key: key2))

        let encrypted = try vault1.encrypt("super_secret_payload")
        #expect(throws: (any Error).self) {
            try vault2.decrypt(encrypted)
        }
    }

    @Test
    func keychainKeyProviderGeneratesAndRetrievesKey() throws {
        let testService = "org.herbsterminal.test.\(UUID().uuidString)"
        let testAccount = "test-key"
        defer {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: testService,
                kSecAttrAccount as String: testAccount
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        let provider1 = KeychainKeyProvider(service: testService, account: testAccount)
        let key1 = try provider1.encryptionKey()

        // Second instance accessing same service and account should retrieve the same key
        let provider2 = KeychainKeyProvider(service: testService, account: testAccount)
        let key2 = try provider2.encryptionKey()

        #expect(key1 == key2)
    }
}
