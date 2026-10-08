import Foundation

/// UTF-8 identity of a path spelling.
///
/// Swift `String` equality folds canonically equivalent Unicode. Filesystem
/// spellings do not: NFC and NFD are different entries and must not share a key.
public struct WorkspacePathByteKey: Hashable, Comparable, Sendable {
    public let bytes: [UInt8]

    public init(_ path: String) {
        bytes = Array(path.utf8)
    }

    public static func < (lhs: WorkspacePathByteKey, rhs: WorkspacePathByteKey) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public var asciiHex: String {
        var encoded = ""
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(Self.hexDigits[Int(byte >> 4)])
            encoded.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return encoded
    }

    private static let hexDigits = Array("0123456789abcdef")
}

enum WorkspacePathOrder {
    static func isBefore(_ first: String, _ second: String) -> Bool {
        let pathComparison = first.compare(
            second,
            options: [.caseInsensitive, .numeric]
        )
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }
        return WorkspacePathByteKey(first) < WorkspacePathByteKey(second)
    }
}
