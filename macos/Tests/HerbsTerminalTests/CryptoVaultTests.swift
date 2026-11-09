import CryptoKit
import Foundation
import Testing
@testable import HerbsTerminal

@Suite("Cryptographic Vault Tests")
struct CryptoVaultTests {

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
}
