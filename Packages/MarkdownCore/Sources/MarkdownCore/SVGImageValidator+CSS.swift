import Foundation

/// CSS scanning for `<style>` text and CSS-valued attributes. Accept/reject only.
extension SVGImageValidator {
    /// CSS functions that load a resource without `url(`.
    private static let disallowedCSSTokens = ["@import", "image-set(", "cross-fade(", "src("]

    static func cssContainsDisallowedReference(_ css: String) -> Bool {
        // Decode escapes first: `u\72l(` and `@\69mport` are `url(` and `@import` to CSS.
        let text = decodingCSSEscapes(css).lowercased()
        if disallowedCSSTokens.contains(where: { text.contains($0) }) {
            return true
        }
        var remainder = text[...]
        while let range = remainder.range(of: "url(") {
            let after = range.upperBound
            guard let close = remainder[after...].firstIndex(of: ")") else { return true }
            let raw = remainder[after ..< close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let reference = unquotedCSSReference(raw), isFragmentToken(reference) else {
                return true
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return false
    }

    /// CSS Syntax §4.3.7: `\` + 1–6 hex digits (+ one optional whitespace), or `\` + any
    /// other character. A trailing `\` or `\` + newline stays as-is, which can only
    /// make the scan stricter.
    static func decodingCSSEscapes(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        var output = String.UnicodeScalarView()
        let scalars = Array(css.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count, scalars[index + 1] != "\n" else {
                output.append(scalar)
                index += 1
                continue
            }
            var cursor = index + 1
            var value: UInt32 = 0
            var digits = 0
            while cursor < scalars.count, digits < 6, let digit = hexValue(scalars[cursor]) {
                value = value * 16 + digit
                digits += 1
                cursor += 1
            }
            if digits == 0 {
                output.append(scalars[index + 1])
                index += 2
                continue
            }
            if cursor < scalars.count, scalars[cursor].properties.isWhitespace {
                cursor += 1
            }
            output.append(value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}")
            index = cursor
        }
        return String(output)
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30 ... 0x39: scalar.value - 0x30
        case 0x41 ... 0x46: scalar.value - 0x41 + 10
        case 0x61 ... 0x66: scalar.value - 0x61 + 10
        default: nil
        }
    }

    private static func unquotedCSSReference(_ raw: String) -> String? {
        guard let first = raw.first, first == "\"" || first == "'" else {
            if raw.contains("\"") || raw.contains("'") { return nil }
            return String(raw)
        }
        guard raw.last == first, raw.count >= 2 else { return nil }
        return String(raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
