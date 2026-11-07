import COpenSSL
import Foundation

// The part of Apple's CryptoKit API the login vault uses, on OpenSSL's libcrypto: 256-bit keys and AES-GCM with a
// 12-byte nonce and a 16-byte tag, so data sealed on a Mac opens here and the other way round.

public struct CryptoKitError: Error {
    public let reason: String
}

public struct SymmetricKeySize: Sendable {
    public let bitCount: Int
    public init(bitCount: Int) { self.bitCount = bitCount }
    public static let bits128 = SymmetricKeySize(bitCount: 128)
    public static let bits192 = SymmetricKeySize(bitCount: 192)
    public static let bits256 = SymmetricKeySize(bitCount: 256)
}

public struct SymmetricKey: Sendable {
    let bytes: [UInt8]
    public var bitCount: Int { bytes.count * 8 }

    public init<D: ContiguousBytes>(data: D) {
        bytes = data.withUnsafeBytes { Array($0) }
    }

    public init(size: SymmetricKeySize) {
        bytes = randomBytes(size.bitCount / 8)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    guard count > 0 else { return bytes }
    precondition(RAND_bytes(&bytes, Int32(count)) == 1, "OpenSSL couldn't produce random bytes")
    return bytes
}

public enum AES {
    public enum GCM {
        public struct Nonce: Sequence, Sendable {
            let bytes: [UInt8]
            public init() { bytes = randomBytes(12) }
            public init<D: DataProtocol>(data: D) throws {
                guard data.count >= 12 else { throw CryptoKitError(reason: "Nonce too short") }
                bytes = Array(data)
            }
            public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
        }

        public struct SealedBox: Sendable {
            public let nonce: Nonce
            public let ciphertext: Data
            public let tag: Data
            public var combined: Data? { Data(nonce.bytes) + ciphertext + tag }

            public init<C: DataProtocol, T: DataProtocol>(nonce: Nonce, ciphertext: C, tag: T) throws {
                guard tag.count == 16 else { throw CryptoKitError(reason: "Tag must be 16 bytes") }
                self.nonce = nonce
                self.ciphertext = Data(ciphertext)
                self.tag = Data(tag)
            }
        }

        public static func seal<P: DataProtocol>(_ message: P, using key: SymmetricKey, nonce: Nonce? = nil) throws -> SealedBox {
            let nonce = nonce ?? Nonce()
            let plain = Array(message)
            var out = [UInt8](repeating: 0, count: plain.count + 16)
            var tag = [UInt8](repeating: 0, count: 16)
            guard let context = EVP_CIPHER_CTX_new() else { throw CryptoKitError(reason: "No cipher context") }
            defer { EVP_CIPHER_CTX_free(context) }
            var length: Int32 = 0, total: Int32 = 0
            guard EVP_EncryptInit_ex(context, cipher(key), nil, nil, nil) == 1,
                  EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, Int32(nonce.bytes.count), nil) == 1,
                  key.bytes.withUnsafeBufferPointer({ k in nonce.bytes.withUnsafeBufferPointer { n in
                      EVP_EncryptInit_ex(context, nil, nil, k.baseAddress, n.baseAddress) } }) == 1,
                  EVP_EncryptUpdate(context, &out, &length, plain, Int32(plain.count)) == 1 else {
                throw CryptoKitError(reason: "AES-GCM encryption failed")
            }
            total = length
            guard out.withUnsafeMutableBufferPointer({ EVP_EncryptFinal_ex(context, $0.baseAddress! + Int(total), &length) }) == 1,
                  EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_GET_TAG, 16, &tag) == 1 else {
                throw CryptoKitError(reason: "AES-GCM encryption failed")
            }
            total += length
            return try SealedBox(nonce: nonce, ciphertext: Data(out[0..<Int(total)]), tag: Data(tag))
        }

        public static func open(_ box: SealedBox, using key: SymmetricKey) throws -> Data {
            let sealed = Array(box.ciphertext)
            var out = [UInt8](repeating: 0, count: sealed.count + 16)
            var tag = Array(box.tag)
            guard let context = EVP_CIPHER_CTX_new() else { throw CryptoKitError(reason: "No cipher context") }
            defer { EVP_CIPHER_CTX_free(context) }
            var length: Int32 = 0, total: Int32 = 0
            guard EVP_DecryptInit_ex(context, cipher(key), nil, nil, nil) == 1,
                  EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, Int32(box.nonce.bytes.count), nil) == 1,
                  key.bytes.withUnsafeBufferPointer({ k in box.nonce.bytes.withUnsafeBufferPointer { n in
                      EVP_DecryptInit_ex(context, nil, nil, k.baseAddress, n.baseAddress) } }) == 1,
                  EVP_DecryptUpdate(context, &out, &length, sealed, Int32(sealed.count)) == 1 else {
                throw CryptoKitError(reason: "AES-GCM decryption failed")
            }
            total = length
            guard EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_TAG, 16, &tag) == 1,
                  out.withUnsafeMutableBufferPointer({ EVP_DecryptFinal_ex(context, $0.baseAddress! + Int(total), &length) }) == 1 else {
                throw CryptoKitError(reason: "Authentication failed")
            }
            total += length
            return Data(out[0..<Int(total)])
        }

        private static func cipher(_ key: SymmetricKey) -> OpaquePointer? {
            switch key.bytes.count {
            case 16: EVP_aes_128_gcm()
            case 24: EVP_aes_192_gcm()
            default: EVP_aes_256_gcm()
            }
        }
    }
}

