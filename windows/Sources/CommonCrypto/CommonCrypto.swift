import CryptoKit
import WinSDK

// CommonCrypto's PBKDF2, as the login vault calls it, on Windows CNG's BCryptDeriveKeyPBKDF2. Keys derived here
// match the ones a Mac or Linux derives from the same Administrator Password, salt and round count.

public typealias CCPBKDFAlgorithm = UInt32
public typealias CCPseudoRandomAlgorithm = UInt32
public typealias CCCryptorStatus = Int32

public let kCCPBKDF2: UInt32 = 2
public let kCCPRFHmacAlgSHA1: UInt32 = 1
public let kCCPRFHmacAlgSHA256: UInt32 = 3
public let kCCPRFHmacAlgSHA512: UInt32 = 5
public let kCCSuccess: Int32 = 0
public let kCCParamError: Int32 = -4300

public func CCKeyDerivationPBKDF(_ algorithm: CCPBKDFAlgorithm, _ password: UnsafePointer<CChar>?, _ passwordLength: Int,
                                 _ salt: UnsafePointer<UInt8>?, _ saltLength: Int, _ prf: CCPseudoRandomAlgorithm,
                                 _ rounds: UInt32, _ derivedKey: UnsafeMutablePointer<UInt8>?, _ derivedKeyLength: Int) -> Int32 {
    guard algorithm == kCCPBKDF2, let derivedKey else { return kCCParamError }
    let name = switch prf {
    case kCCPRFHmacAlgSHA1: "SHA1"
    case kCCPRFHmacAlgSHA512: "SHA512"
    default: "SHA256"
    }
    guard let hmac = CNG.provider(name, flags: ULONG(BCRYPT_ALG_HANDLE_HMAC_FLAG)) else { return kCCParamError }
    defer { BCryptCloseAlgorithmProvider(hmac, 0) }
    let passwordBytes = UnsafeMutableRawPointer(mutating: password)?.assumingMemoryBound(to: UCHAR.self)
    let saltBytes = UnsafeMutablePointer(mutating: salt)
    let status = BCryptDeriveKeyPBKDF2(hmac, passwordBytes, ULONG(passwordLength), saltBytes, ULONG(saltLength),
                                       ULONGLONG(rounds), derivedKey, ULONG(derivedKeyLength), 0)
    return status >= 0 ? kCCSuccess : kCCParamError
}
