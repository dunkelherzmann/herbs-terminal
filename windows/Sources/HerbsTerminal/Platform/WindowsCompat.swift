import CryptoKit
import Foundation
import ucrt

// Names the shared macOS sources use that Windows spells differently or doesn't have. Declarations in this module
// take precedence over the imported C ones, so the shared files compile unchanged.

// Security.framework's random source, which the macOS sources call for tokens and salts.
nonisolated(unsafe) let kSecRandomDefault: OpaquePointer? = nil

@discardableResult
func SecRandomCopyBytes(_ rnd: OpaquePointer?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    let random = CNG.randomBytes(count)
    random.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: count) }
    return 0
}

/// POSIX permissions don't apply on NTFS: files in the user's profile are private to the user by its ACL already.
@discardableResult
func chmod(_ path: String, _ mode: Int) -> Int32 { 0 }
