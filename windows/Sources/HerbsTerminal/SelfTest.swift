import CryptoKit
import Foundation

/// `HerbsTerminal.exe --self-test`: checks the parts that don't need a window. Exit code 0 means everything passed.
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: @autoclosure () throws -> Bool) {
        let passed = (try? ok()) ?? false
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL")  \(name)")
    }

    static func run() -> Int32 {
        failures = 0

        // AES-GCM round trip and tamper detection.
        let key = SymmetricKey(size: .bits256)
        let box = try? AES.GCM.seal(Data("secret".utf8), using: key)
        check("AES-GCM opens what it sealed", try AES.GCM.open(box!, using: key) == Data("secret".utf8))
        if let box {
            var tampered = box.ciphertext
            tampered[tampered.startIndex] ^= 1
            let bad = try? AES.GCM.SealedBox(nonce: box.nonce, ciphertext: tampered, tag: box.tag)
            check("AES-GCM rejects tampered data", (try? AES.GCM.open(bad!, using: key)) == nil)
        }
        // Known-answer test (NIST GCM test case 13: zero key, zero nonce, empty message).
        let zero = SymmetricKey(data: Data(count: 32))
        let empty = try? AES.GCM.seal(Data(), using: zero, nonce: AES.GCM.Nonce(data: Data(count: 12)))
        check("AES-256-GCM matches the NIST test vector",
              empty?.tag.map { String(format: "%02x", $0) }.joined() == "530f8afbc74536b9a963b4f1c4cb738b")

        vaultChecks()
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
