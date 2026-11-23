import Foundation

/// CSS scanning for `<style>` text and CSS-valued attributes. Accept/reject only.
extension SVGImageValidator {
    /// CSS functions that load a resource without `url(`.
    private static let disallowedCSSTokens = ["@import", "image-set(", "cross-fade(", "src("]

    static func cssContainsDisallowedReference(_ css: String) -> Bool {
        // Decode escapes first: `u\72l(` and `@\69mport` are `url(` and `@import` to CSS.
        // Scan scalars, not graphemes: `(` + U+0301 is one `Character`, so a `String`
        // search misses `url(\u{301}#a)` while CSS still reads a `url(` function.
        let text = Array(decodingCSSEscapes(normalizingCSSNewlines(css)).lowercased().unicodeScalars)
        if disallowedCSSTokens.contains(where: { firstIndex(of: $0, in: text, from: 0) != nil }) {
            return true
        }
        var position = 0
        while let start = firstIndex(of: "url(", in: text, from: position) {
            let after = start + 4
            guard let close = text[after...].firstIndex(of: ")") else { return true }
            var raw = String.UnicodeScalarView()
            raw.append(contentsOf: text[after ..< close])
            guard let reference = unquotedCSSReference(String(raw).trimmingCharacters(in: urlEdgeSpaces)),
                  isFragmentToken(reference)
            else {
                return true
            }
            position = close + 1
        }
        return false
    }

    private static func firstIndex(of token: String, in text: [Unicode.Scalar], from start: Int) -> Int? {
        let needle = Array(token.unicodeScalars)
        guard text.count >= needle.count, start <= text.count - needle.count else { return nil }
        return (start ... text.count - needle.count).first { text[$0 ..< $0 + needle.count].elementsEqual(needle) }
    }

    /// CSS Syntax §3.3: CRLF, CR and FF are one LF before tokenizing, so `\75` + CRLF
    /// + `rl(` is `url(` to CSS.
    static func normalizingCSSNewlines(_ css: String) -> String {
        guard css.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\u{0C}" }) else { return css }
        var output = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in css.unicodeScalars {
            defer { previousWasCarriageReturn = scalar == "\r" }
            switch scalar {
            case "\r", "\u{0C}": output.append("\n")
            case "\n" where previousWasCarriageReturn: continue
            default: output.append(scalar)
            }
        }
        return String(output)
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
            // Only CSS whitespace ends an escape. NBSP and other Unicode spaces stay in
            // the value, as they do in WebKit. Newlines are already normalized to LF.
            if cursor < scalars.count, scalars[cursor] == " " || scalars[cursor] == "\t" || scalars[cursor] == "\n" {
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
        let scalars = raw.unicodeScalars
        guard let first = scalars.first, first == "\"" || first == "'" else {
            if scalars.contains("\"") || scalars.contains("'") { return nil }
            return raw
        }
        guard scalars.last == first, scalars.count >= 2 else { return nil }
        return String(String.UnicodeScalarView(scalars.dropFirst().dropLast())).trimmingCharacters(in: urlEdgeSpaces)
    }

    /// WHATWG URL parsing strips only C0 controls and space from either end. Foundation's
    /// whitespace set also trims NBSP and other Unicode spaces, so `&#160;#a` passed as a
    /// fragment while WebKit resolves it as a sibling path (`%C2%A0#a`).
    static let urlEdgeSpaces = CharacterSet(charactersIn: "\u{0}" ... "\u{20}")
}
