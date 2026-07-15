struct WorkspacePathByteKey: Hashable, Comparable {
    let bytes: [UInt8]

    init(_ path: String) {
        bytes = Array(path.utf8)
    }

    static func < (lhs: WorkspacePathByteKey, rhs: WorkspacePathByteKey) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    var asciiHex: String {
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
