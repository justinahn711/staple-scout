import Foundation
import CryptoKit
import Security

enum SessionCrypto {
    static func token(prefix: String, bytes count: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SessionError.entropyUnavailable
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func isToken(_ token: String, prefix: String) -> Bool {
        token.utf8.count == prefix.utf8.count + 64 && token.hasPrefix(prefix)
            && token.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func hash(_ token: String) -> String {
        // These are uniformly random 256-bit credentials, never passwords.
        SHA256.hash(data: Data(("thrifty-client-sessions-v1:" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
