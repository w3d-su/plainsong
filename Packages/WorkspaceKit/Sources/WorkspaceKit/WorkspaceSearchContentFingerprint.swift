import CryptoKit
import Foundation

/// Stable identity for the exact UTF-8 text searched by `TextSearchEngine`.
///
/// The digest is the lowercase hexadecimal SHA-256 of the text's UTF-8 bytes. The byte
/// count is carried separately so callers can compare both values without relying on
/// process-randomized Swift hashing or filesystem metadata.
public struct WorkspaceSearchContentFingerprint: Sendable, Equatable, Hashable {
    public let sha256Digest: String
    public let utf8ByteCount: Int

    /// Pure fingerprinting entry point for disk text, dirty overlays, and activated sessions.
    public init(text: String) {
        let utf8 = Data(text.utf8)
        sha256Digest = SHA256.hash(data: utf8).map { byte in
            String(format: "%02x", byte)
        }.joined()
        utf8ByteCount = utf8.count
    }
}
