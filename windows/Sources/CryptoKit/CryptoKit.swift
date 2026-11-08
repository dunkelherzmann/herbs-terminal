import Foundation
import WinSDK

// The part of Apple's CryptoKit API the login vault uses, on Windows CNG (bcrypt.dll): 256-bit keys and AES-GCM with
// a 12-byte nonce and a 16-byte tag, so data sealed on a Mac or on Linux opens here and the other way round.

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
        bytes = CNG.randomBytes(size.bitCount / 8)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
}

/// Small helpers over bcrypt.dll.
public enum CNG {
    /// Cryptographically secure random bytes from the system's preferred generator.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return bytes }
        let status = BCryptGenRandom(nil, &bytes, ULONG(count), ULONG(BCRYPT_USE_SYSTEM_PREFERRED_RNG))
        precondition(status >= 0, "Windows couldn't produce random bytes")
        return bytes
    }

    /// Opens an algorithm provider by its CNG name ("AES", "SHA256"…).
    public static func provider(_ name: String, flags: ULONG = 0) -> BCRYPT_ALG_HANDLE? {
        var handle: BCRYPT_ALG_HANDLE?
        let status = name.withCString(encodedAs: UTF16.self) { BCryptOpenAlgorithmProvider(&handle, $0, nil, flags) }
        return status >= 0 ? handle : nil
    }
}

public enum AES {
    public enum GCM {
        public struct Nonce: Sequence, Sendable {
            let bytes: [UInt8]
            public init() { bytes = CNG.randomBytes(12) }
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
            var tag = [UInt8](repeating: 0, count: 16)
            let out = try run(key: key, nonce: nonce, input: plain, tag: &tag, encrypt: true)
            return try SealedBox(nonce: nonce, ciphertext: Data(out), tag: Data(tag))
        }

        public static func open(_ box: SealedBox, using key: SymmetricKey) throws -> Data {
            var tag = Array(box.tag)
            return Data(try run(key: key, nonce: box.nonce, input: Array(box.ciphertext), tag: &tag, encrypt: false))
        }

        private static func run(key: SymmetricKey, nonce: Nonce, input: [UInt8], tag: inout [UInt8], encrypt: Bool) throws -> [UInt8] {
            guard let algorithm = CNG.provider("AES") else { throw CryptoKitError(reason: "AES is unavailable") }
            defer { BCryptCloseAlgorithmProvider(algorithm, 0) }
            let mode = Array("ChainingModeGCM".utf16) + [0]
            let modeStatus = mode.withUnsafeBufferPointer { buffer in
                "ChainingMode".withCString(encodedAs: UTF16.self) { property in
                    BCryptSetProperty(algorithm, property, UnsafeMutablePointer(mutating: buffer.baseAddress!).withMemoryRebound(to: UCHAR.self, capacity: buffer.count * 2) { $0 },
                                      ULONG(buffer.count * 2), 0)
                }
            }
            guard modeStatus >= 0 else { throw CryptoKitError(reason: "AES-GCM is unavailable") }

            var keyHandle: BCRYPT_KEY_HANDLE?
            var keyBytes = key.bytes
            guard BCryptGenerateSymmetricKey(algorithm, &keyHandle, nil, 0, &keyBytes, ULONG(keyBytes.count), 0) >= 0, let keyHandle else {
                throw CryptoKitError(reason: "Invalid key")
            }
            defer { BCryptDestroyKey(keyHandle) }

            var nonceBytes = nonce.bytes
            var output = [UInt8](repeating: 0, count: max(input.count, 1))
            var inputBytes = input.isEmpty ? [0] : input
            var written: ULONG = 0
            let status: NTSTATUS = nonceBytes.withUnsafeMutableBufferPointer { noncePointer in
                tag.withUnsafeMutableBufferPointer { tagPointer in
                    // BCRYPT_INIT_AUTH_MODE_INFO, spelled out: the macro doesn't reach Swift.
                    var info = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO()
                    info.cbSize = ULONG(MemoryLayout<BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO>.size)
                    info.dwInfoVersion = 1
                    info.pbNonce = noncePointer.baseAddress
                    info.cbNonce = ULONG(noncePointer.count)
                    info.pbTag = tagPointer.baseAddress
                    info.cbTag = ULONG(tagPointer.count)
                    return withUnsafeMutablePointer(to: &info) { infoPointer in
                        encrypt
                            ? BCryptEncrypt(keyHandle, &inputBytes, ULONG(input.count), infoPointer, nil, 0, &output, ULONG(output.count), &written, 0)
                            : BCryptDecrypt(keyHandle, &inputBytes, ULONG(input.count), infoPointer, nil, 0, &output, ULONG(output.count), &written, 0)
                    }
                }
            }
            guard status >= 0 else {
                throw CryptoKitError(reason: encrypt ? "AES-GCM encryption failed" : "Authentication failed")
            }
            return Array(output.prefix(Int(written)))
        }
    }
}
