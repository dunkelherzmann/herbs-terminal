import COpenSSL

// CommonCrypto's PBKDF2, as the login vault calls it, on OpenSSL's PKCS5_PBKDF2_HMAC. Keys derived here match
// the ones a Mac derives from the same Administrator Password, salt and round count.

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
    let digest: OpaquePointer?
    switch prf {
    case kCCPRFHmacAlgSHA1: digest = EVP_sha1()
    case kCCPRFHmacAlgSHA512: digest = EVP_sha512()
    default: digest = EVP_sha256()
    }
    let empty: [UInt8] = [0]
    let saltPointer = salt ?? empty.withUnsafeBufferPointer { $0.baseAddress! }
    return PKCS5_PBKDF2_HMAC(password, Int32(passwordLength), saltPointer, Int32(saltLength), Int32(rounds), digest,
                             Int32(derivedKeyLength), derivedKey) == 1 ? kCCSuccess : kCCParamError
}
