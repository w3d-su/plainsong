import CoreFoundation
import Foundation

/// A schema v1 color theme. Missing slots inherit the built-in palette; `nil` dark
/// inherits the built-in dark palette for every slot. Values are `#RRGGBB` or
/// `#RRGGBBAA` and never CSS text.
public struct CustomThemeDocument: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumByteCount = 64 * 1024
    public static let builtInIdentifiers: Set<String> = ["standard", "graphite"]
    /// NFC-normalized name, in Unicode scalars. `String.count` is grapheme clusters,
    /// and one cluster can stack enough combining marks to hide a much longer value.
    public static let maximumNameScalarCount = 128

    /// Closed editor slots. `gutter` is the gutter track; omitted, it follows the editor background.
    public static let editorColorKeys = [
        "text",
        "muted",
        "heading",
        "link",
        "code",
        "codeBackground",
        "frontmatter",
        "frontmatterBackground",
        "listMarker",
        "tsxKeyword",
        "tsxString",
        "tsxTag",
        "tsxAttribute",
        "tsxPunctuation",
        "background",
        "selection",
        "caret",
        "gutter",
    ]

    /// Closed preview slots. Names match the bundled custom properties without the `--preview-` / `--` prefix.
    /// Preview tokens are validated with the file and are not applied until a later bridge change.
    public static let previewColorKeys = [
        "fg",
        "bg",
        "muted",
        "accent",
        "border",
        "separator",
        "stripe",
        "code-bg",
        "caution-bg",
        "caution-border",
        "caution-fg",
        "hl-keyword",
        "hl-string",
        "hl-number",
        "hl-comment",
        "hl-function",
        "hl-type",
        "hl-attribute",
        "hl-declaration",
        "hl-preprocessor",
        "hl-link",
        "hl-addition-bg",
        "hl-deletion-bg",
    ]

    public var id: String
    public var name: String
    public var light: CustomThemePalette
    public var dark: CustomThemePalette?

    public init(id: String, name: String, light: CustomThemePalette, dark: CustomThemePalette? = nil) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }
}

public struct CustomThemePalette: Equatable, Sendable {
    public var editor: [String: String]
    public var preview: [String: String]

    public init(editor: [String: String] = [:], preview: [String: String] = [:]) {
        self.editor = editor
        self.preview = preview
    }
}

public enum CustomThemeValidationFailure: Equatable, Sendable, Error {
    case exceedsMaximumSize(byteCount: Int)
    case invalidUTF8
    case invalidJSON
    case unknownField(String)
    case missingField(String)
    case unsupportedSchemaVersion(Int)
    case identifier
    case reservedIdentifier(String)
    case name
    case color(String)
    case nonOpaqueColor(String)
}

public enum CustomThemeValidation {
    public static func validate(
        _ data: Data,
        reservedIdentifiers: Set<String> = CustomThemeDocument.builtInIdentifiers
    ) -> Result<CustomThemeDocument, CustomThemeValidationFailure> {
        switch jsonObject(data) {
        case let .success(root):
            document(from: root, reservedIdentifiers: reservedIdentifiers)
        case let .failure(failure):
            .failure(failure)
        }
    }

    private static func jsonObject(
        _ data: Data
    ) -> Result<[String: Any], CustomThemeValidationFailure> {
        if data.count > CustomThemeDocument.maximumByteCount {
            return .failure(.exceedsMaximumSize(byteCount: data.count))
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        if CustomThemeJSONStructure.exceedsNestingLimit(text) || CustomThemeJSONStructure.hasDuplicateKeys(text) {
            return .failure(.invalidJSON)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.invalidJSON)
        }
        guard let root = parsed as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        return .success(root)
    }

    private static func document(
        from root: [String: Any],
        reservedIdentifiers: Set<String>
    ) -> Result<CustomThemeDocument, CustomThemeValidationFailure> {
        if let unknown = unknownField(in: root, allowed: rootKeys, path: "") {
            return .failure(.unknownField(unknown))
        }
        switch requiredSchemaVersion(in: root) {
        case .success:
            break
        case let .failure(failure):
            return .failure(failure)
        }

        let identifier: String
        let name: String
        switch identity(in: root, reservedIdentifiers: reservedIdentifiers) {
        case let .success(parsed):
            identifier = parsed.identifier
            name = parsed.name
        case let .failure(failure):
            return .failure(failure)
        }

        guard let lightValue = root["light"] else {
            return .failure(.missingField("light"))
        }
        let light: CustomThemePalette
        switch palette(lightValue, path: "light") {
        case let .success(parsedLight):
            light = parsedLight
        case let .failure(failure):
            return .failure(failure)
        }
        let dark: CustomThemePalette?
        switch optionalPalette(root["dark"], path: "dark") {
        case let .success(parsedDark):
            dark = parsedDark
        case let .failure(failure):
            return .failure(failure)
        }
        return .success(CustomThemeDocument(id: identifier, name: name, light: light, dark: dark))
    }

    private static func requiredSchemaVersion(
        in root: [String: Any]
    ) -> Result<Void, CustomThemeValidationFailure> {
        guard let schemaValue = root["schemaVersion"] else {
            return .failure(.missingField("schemaVersion"))
        }
        guard let schemaVersion = strictInteger(schemaValue) else {
            return .failure(.invalidJSON)
        }
        guard schemaVersion == CustomThemeDocument.schemaVersion else {
            return .failure(.unsupportedSchemaVersion(schemaVersion))
        }
        return .success(())
    }

    private static func identity(
        in root: [String: Any],
        reservedIdentifiers: Set<String>
    ) -> Result<(identifier: String, name: String), CustomThemeValidationFailure> {
        let identifier: String
        switch requiredString("id", in: root) {
        case let .success(value):
            identifier = value
        case let .failure(failure):
            return .failure(failure)
        }
        if let failure = identifierFailure(identifier, reservedIdentifiers: reservedIdentifiers) {
            return .failure(failure)
        }

        let name: String
        switch requiredString("name", in: root) {
        case let .success(value):
            name = value
        case let .failure(failure):
            return .failure(failure)
        }
        guard let normalizedName = normalizedName(name) else {
            return .failure(.name)
        }
        return .success((identifier, normalizedName))
    }

    private static func requiredString(
        _ key: String,
        in root: [String: Any]
    ) -> Result<String, CustomThemeValidationFailure> {
        guard let value = root[key] else {
            return .failure(.missingField(key))
        }
        guard let text = value as? String else {
            return .failure(.invalidJSON)
        }
        return .success(text)
    }

    private static func identifierFailure(
        _ identifier: String,
        reservedIdentifiers: Set<String>
    ) -> CustomThemeValidationFailure? {
        guard isIdentifier(identifier) else {
            return .identifier
        }
        guard !reservedIdentifiers.contains(identifier) else {
            return .reservedIdentifier(identifier)
        }
        return nil
    }

    private static func optionalPalette(
        _ value: Any?,
        path: String
    ) -> Result<CustomThemePalette?, CustomThemeValidationFailure> {
        guard let value else {
            return .success(nil)
        }
        switch palette(value, path: path) {
        case let .success(parsed):
            return .success(parsed)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    public static func isIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1 ... 64).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) || scalar == "-"
        }
    }

    public static func isHexColor(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7 || scalars.count == 9, scalars.first == "#" else { return false }
        return scalars.dropFirst()
            .allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) || ("A" ... "F").contains($0) }
    }

    private static let rootKeys: Set<String> = ["schemaVersion", "id", "name", "light", "dark"]
    private static let paletteKeys: Set<String> = ["editor", "preview"]

    private static func palette(
        _ value: Any,
        path: String
    ) -> Result<CustomThemePalette, CustomThemeValidationFailure> {
        if value is NSNull {
            return .failure(.invalidJSON)
        }
        guard let object = value as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        if let unknown = unknownField(in: object, allowed: paletteKeys, path: path) {
            return .failure(.unknownField(unknown))
        }

        let editor: [String: String]
        switch colors(
            object["editor"],
            path: "\(path).editor",
            allowed: Set(CustomThemeDocument.editorColorKeys),
            opaqueKeys: opaqueEditorColorKeys
        ) {
        case let .success(parsed):
            editor = parsed
        case let .failure(failure):
            return .failure(failure)
        }

        let preview: [String: String]
        switch colors(
            object["preview"],
            path: "\(path).preview",
            allowed: Set(CustomThemeDocument.previewColorKeys),
            opaqueKeys: []
        ) {
        case let .success(parsed):
            preview = parsed
        case let .failure(failure):
            return .failure(failure)
        }
        return .success(CustomThemePalette(editor: editor, preview: preview))
    }

    private static let opaqueEditorColorKeys: Set<String> = ["text", "caret", "background"]

    private static func colors(
        _ value: Any?,
        path: String,
        allowed: Set<String>,
        opaqueKeys: Set<String>
    ) -> Result<[String: String], CustomThemeValidationFailure> {
        guard let value else {
            return .success([:])
        }
        if value is NSNull {
            return .failure(.invalidJSON)
        }
        guard let object = value as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        if let unknown = unknownField(in: object, allowed: allowed, path: path) {
            return .failure(.unknownField(unknown))
        }

        var colors: [String: String] = [:]
        for key in allowed.sorted() {
            guard let raw = object[key] else { continue }
            guard let text = raw as? String, isHexColor(text) else {
                return .failure(.color("\(path).\(key)"))
            }
            if opaqueKeys.contains(key), !isOpaqueHexColor(text) {
                return .failure(.nonOpaqueColor("\(path).\(key)"))
            }
            colors[key] = text
        }
        return .success(colors)
    }

    /// Stores the trimmed NFC form. Callers display that string, so leading spaces cannot
    /// impersonate a built-in name and bidi/format characters never reach the picker.
    private static func normalizedName(_ name: String) -> String? {
        let normalized = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= CustomThemeDocument.maximumNameScalarCount
        else {
            return nil
        }
        let hasHiddenScalar = normalized.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format:
                true
            default:
                false
            }
        }
        return hasHiddenScalar ? nil : normalized
    }

    private static func isOpaqueHexColor(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        if scalars.count == 7 {
            return true
        }
        guard scalars.count == 9 else { return false }
        let alpha = String(String.UnicodeScalarView(scalars.suffix(2)))
        return alpha.caseInsensitiveCompare("ff") == .orderedSame
    }

    private static func unknownField(in object: [String: Any], allowed: Set<String>, path: String) -> String? {
        guard let key = object.keys.filter({ !allowed.contains($0) }).sorted().first else {
            return nil
        }
        return path.isEmpty ? key : "\(path).\(key)"
    }

    /// JSON booleans are `NSNumber`s too. Reject those, and reject fractional numbers.
    private static func strictInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue.rounded(.towardZero) == doubleValue else {
            return nil
        }
        guard doubleValue >= Double(Int.min), doubleValue <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }
}

/// Depth and duplicate-key checks that `JSONSerialization` does not report.
/// A duplicate is rejected only when the scan completes; a scan that cannot
/// recognize the text leaves the decision to `JSONSerialization`.
private enum CustomThemeJSONStructure {
    /// Schema v1 nests at most root, palette, then color map. Anything deeper is not a theme.
    static let maximumDepth = 32

    static func exceedsNestingLimit(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for scalar in text.unicodeScalars {
            if inString {
                if escaped {
                    escaped = false
                    continue
                }
                if scalar == "\\" {
                    escaped = true
                    continue
                }
                if scalar == "\"" {
                    inString = false
                }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
                if depth > maximumDepth {
                    return true
                }
            case "}", "]":
                if depth > 0 {
                    depth -= 1
                }
            default:
                break
            }
        }
        return false
    }

    static func hasDuplicateKeys(_ text: String) -> Bool {
        var scanner = Scanner(text)
        return scanner.scan() == .duplicate
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        enum Outcome {
            case clean
            case duplicate
            case unrecognized
        }

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        mutating func scan() -> Outcome {
            skipWhitespace()
            let value = parseValue()
            guard value == .clean else { return value }
            skipWhitespace()
            return index == scalars.count ? .clean : .unrecognized
        }

        private mutating func parseValue() -> Outcome {
            skipWhitespace()
            guard let scalar = peek() else { return .unrecognized }
            switch scalar {
            case "{":
                return parseObject()
            case "[":
                return parseArray()
            case "\"":
                return parseString() == nil ? .unrecognized : .clean
            case "t":
                return consumeLiteral("true")
            case "f":
                return consumeLiteral("false")
            case "n":
                return consumeLiteral("null")
            case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                return skipNumber() ? .clean : .unrecognized
            default:
                return .unrecognized
            }
        }

        private mutating func parseObject() -> Outcome {
            guard consume("{") else { return .unrecognized }
            skipWhitespace()
            if consume("}") {
                return .clean
            }
            var keys: Set<String> = []
            while true {
                guard let key = parseString() else { return .unrecognized }
                if keys.contains(key) {
                    return .duplicate
                }
                keys.insert(key)
                skipWhitespace()
                guard consume(":") else { return .unrecognized }
                let value = parseValue()
                guard value == .clean else { return value }
                skipWhitespace()
                if consume("}") {
                    return .clean
                }
                guard consume(",") else { return .unrecognized }
                skipWhitespace()
            }
        }

        private mutating func parseArray() -> Outcome {
            guard consume("[") else { return .unrecognized }
            skipWhitespace()
            if consume("]") {
                return .clean
            }
            while true {
                let value = parseValue()
                guard value == .clean else { return value }
                skipWhitespace()
                if consume("]") {
                    return .clean
                }
                guard consume(",") else { return .unrecognized }
                skipWhitespace()
            }
        }

        private mutating func parseString() -> String? {
            guard consume("\"") else { return nil }
            var decoded = ""
            while let scalar = peek() {
                index += 1
                if scalar == "\"" {
                    return decoded
                }
                if scalar == "\\" {
                    guard let escaped = parseEscape() else { return nil }
                    decoded.unicodeScalars.append(escaped)
                    continue
                }
                if scalar.value < 0x20 {
                    return nil
                }
                decoded.unicodeScalars.append(scalar)
            }
            return nil
        }

        private mutating func parseEscape() -> Unicode.Scalar? {
            guard let scalar = peek() else { return nil }
            index += 1
            switch scalar {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u": return parseUnicodeEscape()
            default: return nil
            }
        }

        private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
            guard let unit = parseHexUnit() else { return nil }
            if (0xD800 ... 0xDBFF).contains(unit) {
                let saved = index
                if consume("\\"), consume("u"), let low = parseHexUnit(), (0xDC00 ... 0xDFFF).contains(low) {
                    let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    return Unicode.Scalar(combined)
                }
                index = saved
                return nil
            }
            if (0xDC00 ... 0xDFFF).contains(unit) {
                return nil
            }
            return Unicode.Scalar(unit)
        }

        private mutating func parseHexUnit() -> UInt32? {
            var unit: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let scalar = peek(), let digit = hexValue(scalar) else { return nil }
                index += 1
                unit = (unit << 4) | digit
            }
            return unit
        }

        private func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
            switch scalar {
            case "0" ... "9": scalar.value - Unicode.Scalar("0").value
            case "a" ... "f": scalar.value - Unicode.Scalar("a").value + 10
            case "A" ... "F": scalar.value - Unicode.Scalar("A").value + 10
            default: nil
            }
        }

        private mutating func skipNumber() -> Bool {
            if peek() == "-" {
                index += 1
            }
            guard let first = peek(), ("0" ... "9").contains(first) else { return false }
            if first == "0" {
                index += 1
            } else {
                while let scalar = peek(), ("0" ... "9").contains(scalar) {
                    index += 1
                }
            }
            if peek() == "." {
                index += 1
                guard let fraction = peek(), ("0" ... "9").contains(fraction) else { return false }
                while let scalar = peek(), ("0" ... "9").contains(scalar) {
                    index += 1
                }
            }
            if peek() == "e" || peek() == "E" {
                index += 1
                if peek() == "+" || peek() == "-" {
                    index += 1
                }
                guard let exponent = peek(), ("0" ... "9").contains(exponent) else { return false }
                while let scalar = peek(), ("0" ... "9").contains(scalar) {
                    index += 1
                }
            }
            return true
        }

        private mutating func consumeLiteral(_ literal: String) -> Outcome {
            for scalar in literal.unicodeScalars {
                guard consume(scalar) else { return .unrecognized }
            }
            return .clean
        }

        private mutating func skipWhitespace() {
            while let scalar = peek(), scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                index += 1
            }
        }

        private func peek() -> Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private mutating func consume(_ expected: Unicode.Scalar) -> Bool {
            guard peek() == expected else { return false }
            index += 1
            return true
        }
    }
}
