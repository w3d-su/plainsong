import Foundation

/// Literal source-text equality without Unicode normalization.
///
/// Swift `String` equality treats canonically equivalent Unicode as equal. Editor source
/// state instead needs the exact UTF-16 code-unit sequence so byte-different input still
/// propagates through versioning, dirty tracking, and App bindings. Foundation's literal
/// comparison keeps that contract for bridged strings; two native strings compare bytes.
public enum ExactSourceText {
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if let matches = nativeUTF8Matches(lhs, rhs) {
            return matches
        }
        return (lhs as NSString).compare(rhs, options: .literal) == .orderedSame
    }

    /// Native strings are valid Unicode, so exact UTF-16 equality is exact UTF-8 byte
    /// equality. `nil` when either side is a bridged (foreign) string.
    public static func nativeUTF8Matches(_ lhs: String, _ rhs: String) -> Bool? {
        let matches = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                left.count == right.count
                    && (left.isEmpty || memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0)
            }
        }
        return matches ?? nil
    }

    /// A native UTF-8 copy of `text`, such as an `NSTextStorage` string.
    ///
    /// A bridged string is foreign to Swift: each `==` on it, which SwiftUI runs on
    /// bindings, `onChange` values and view inputs, takes the normalizing slow path one
    /// `characterAtIndex:` at a time (tens of milliseconds to seconds for 1 MiB). Native
    /// strings compare with a byte prefix scan. Returns `nil` when `text` contains an
    /// unpaired surrogate, which a native string cannot represent exactly.
    public static func nativeCopy(of text: NSString) -> String? {
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        var byteCount = 0
        // A loss byte of 0 stops at the first character UTF-8 cannot encode.
        guard CFStringGetBytes(string, range, encoding, 0, false, nil, 0, &byteCount) == range.length else {
            return nil
        }
        return String(unsafeUninitializedCapacity: byteCount) { buffer in
            var written = 0
            CFStringGetBytes(string, range, encoding, 0, false, buffer.baseAddress, byteCount, &written)
            return written
        }
    }
}
