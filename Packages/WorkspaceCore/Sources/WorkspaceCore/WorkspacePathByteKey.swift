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

public enum WorkspacePathOrder {
    private static let comparisonOptions: String.CompareOptions = [.caseInsensitive, .numeric]

    public static func isBefore(_ first: String, _ second: String) -> Bool {
        let pathComparison = first.compare(second, options: comparisonOptions)
        if pathComparison != .orderedSame {
            return pathComparison == .orderedAscending
        }
        return WorkspacePathByteKey(first) < WorkspacePathByteKey(second)
    }

    struct Key {
        private static let maximumDigitRun = 9
        private let path: String
        private let ascii: String?

        init(_ path: String) {
            self.path = path
            var source = path
            ascii = source.withUTF8(Self.asciiKey)
        }

        func isBefore(_ other: Self) -> Bool {
            guard let ascii, let otherASCII = other.ascii else {
                return WorkspacePathOrder.isBefore(path, other.path)
            }
            return ascii == otherASCII ? path < other.path : ascii < otherASCII
        }

        private static func asciiKey(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
            let zero: UInt8 = 48
            var key: [UInt8] = []
            key.reserveCapacity(bytes.count)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                guard byte < 128 else { return nil }
                if (48 ... 57).contains(byte) {
                    let start = index
                    repeat {
                        index += 1
                    } while index < bytes.count && (48 ... 57).contains(bytes[index])
                    guard index - start <= maximumDigitRun else {
                        return nil
                    }
                    var significant = start
                    while significant < index, bytes[significant] == zero {
                        significant += 1
                    }
                    key.append(zero)
                    key.append(UInt8(index - significant))
                    key.append(contentsOf: bytes[significant ..< index])
                } else {
                    key.append((65 ... 90).contains(byte) ? byte + 32 : byte)
                    index += 1
                }
            }
            return String(bytes: key, encoding: .utf8)
        }
    }
}
