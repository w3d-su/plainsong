import Foundation
import Yams

public enum FrontmatterValue: Equatable, Sendable {
    case string(String)
    case date(String)
    case stringList([String])
    case bool(Bool)
    case raw(String)

    public var stringValue: String {
        switch self {
        case let .string(value), let .date(value), let .raw(value):
            value
        case let .stringList(values):
            values.joined(separator: ", ")
        case let .bool(value):
            value ? "true" : "false"
        }
    }

    public var isEditable: Bool {
        switch self {
        case .bool, .date, .string, .stringList:
            true
        case .raw:
            false
        }
    }
}

public struct FrontmatterField: Identifiable, Equatable, Sendable {
    public let key: String
    public let value: FrontmatterValue
    public let rawValue: String?

    public var id: String {
        key
    }

    public var isEditable: Bool {
        value.isEditable
    }

    public init(key: String, value: FrontmatterValue, rawValue: String? = nil) {
        self.key = key
        self.value = value
        self.rawValue = rawValue
    }
}

public struct FrontmatterBlock: Equatable, Sendable {
    public enum Format: Equatable, Sendable {
        case yaml
        /// A leading `+++` block (Hugo, Zola). It is recognized so the inspector neither
        /// offers to add a second block above it nor parses or rewrites it.
        case toml
    }

    /// The source between the block's fences (TOML source when `format` is `.toml`).
    public let rawYAML: String
    public let fields: [FrontmatterField]
    public let lineEnding: String
    public let format: Format

    public var fieldValues: [String: FrontmatterValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
    }

    public init(
        rawYAML: String,
        fields: [FrontmatterField],
        lineEnding: String,
        format: Format = .yaml
    ) {
        self.rawYAML = rawYAML
        self.fields = fields
        self.lineEnding = lineEnding
        self.format = format
    }
}

public struct FrontmatterError: Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct FrontmatterParseResult: Equatable, Sendable {
    public let block: FrontmatterBlock?
    public let error: FrontmatterError?

    public var hasFrontmatter: Bool {
        block != nil
    }

    public var isMalformed: Bool {
        error != nil
    }

    public init(block: FrontmatterBlock?, error: FrontmatterError? = nil) {
        self.block = block
        self.error = error
    }
}

public enum Frontmatter {
    public static func isPlainCalendarDate(_ value: String) -> Bool {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }

        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }

        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    public static func parse(_ text: String) -> FrontmatterParseResult {
        switch scanFences(in: text) {
        case .absent:
            FrontmatterParseResult(block: nil)
        case let .missingClosing(rawYAML, lineEnding):
            FrontmatterParseResult(
                block: FrontmatterBlock(rawYAML: rawYAML, fields: [], lineEnding: lineEnding),
                error: FrontmatterError(message: "Missing closing frontmatter delimiter.")
            )
        case let .closed(bounds):
            parseClosedBlock(bounds)
        case let .toml(bounds):
            FrontmatterParseResult(
                block: FrontmatterBlock(
                    rawYAML: bounds.rawYAML,
                    fields: [],
                    lineEnding: bounds.lineEnding,
                    format: .toml
                ),
                error: FrontmatterError(message: "TOML frontmatter is read-only here. Edit it in the source.")
            )
        }
    }

    /// Rewrites one key of a closed YAML block, or returns `nil` when the block cannot be
    /// parsed or the edit would not read back as `value` (a duplicate key, a lost key, or
    /// a value YAML would load as another type or structure).
    public static func updating(_ text: String, key: String, value: FrontmatterValue) -> String? {
        switch scanFences(in: text) {
        case let .closed(bounds):
            guard parseClosedBlock(bounds).error == nil else { return nil }
            guard let updatedYAML = try? replacing(
                rawYAML: bounds.rawYAML, key: key, value: value, lineEnding: bounds.lineEnding
            ), writebackReadsBack(
                updatedYAML,
                originalYAML: bounds.rawYAML,
                key: key,
                value: value
            ) else { return nil }
            return "---" + bounds.lineEnding + updatedYAML + "---" + bounds.afterClosingDelimiter
        case .absent, .missingClosing, .toml:
            return nil
        }
    }

    public static func insertingDefaultBlock(into text: String, date: String) -> String {
        let lineEnding = preferredLineEnding(in: text)
        let frontmatter = [
            "---",
            #"title: ""#,
            "date: \(date)",
            "tags: []",
            "draft: false",
            "---",
        ].joined(separator: lineEnding)

        guard !text.isEmpty else {
            return frontmatter + lineEnding
        }
        return frontmatter + lineEnding + text
    }
}

private extension Frontmatter {
    struct Bounds {
        let rawYAML: String
        let lineEnding: String
        let afterClosingDelimiter: String
    }

    enum FenceScan {
        case absent
        case missingClosing(rawYAML: String, lineEnding: String)
        case closed(Bounds)
        case toml(Bounds)
    }

    static func parseClosedBlock(_ bounds: Bounds) -> FrontmatterParseResult {
        do {
            let mapping = try loadMapping(from: bounds.rawYAML)
            let orderedKeys = orderedKeys(in: bounds.rawYAML, mapping: mapping)
            let fields = orderedKeys.map { key in
                let rawValue = rawValueSource(for: key, in: bounds.rawYAML, lineEnding: bounds.lineEnding)
                return FrontmatterField(
                    key: key,
                    value: frontmatterValue(for: key, yamlValue: mapping[key], rawValue: rawValue),
                    rawValue: rawValue
                )
            }
            return FrontmatterParseResult(
                block: FrontmatterBlock(rawYAML: bounds.rawYAML, fields: fields, lineEnding: bounds.lineEnding)
            )
        } catch {
            return FrontmatterParseResult(
                block: FrontmatterBlock(rawYAML: bounds.rawYAML, fields: [], lineEnding: bounds.lineEnding),
                error: FrontmatterError(message: String(describing: error))
            )
        }
    }

    /// Fences match the preview's `remark-frontmatter` gate (`preview-src/src/frontmatter.ts`)
    /// and the editor's fence scanner: `---` at the very start, then only spaces or tabs on
    /// that line; the first later line of `---` and optional spaces or tabs closes it. A
    /// closed `+++` block is TOML. Disagreeing here let the inspector offer Add over a block
    /// the editor already highlighted as frontmatter, inserting a second block above it.
    static func scanFences(in text: String) -> FenceScan {
        let storage = text as NSString
        guard storage.length >= 3 else { return .absent }
        let marker = storage.substring(with: NSRange(location: 0, length: 3))
        guard marker == "---" || marker == "+++",
              let openingDelimiterEnd = fenceLineEnd(marker, from: 0, in: storage)
        else {
            return .absent
        }
        let isTOML = marker == "+++"

        let openingEnding = lineEnding(at: openingDelimiterEnd, in: storage) ?? "\n"
        let rawStart = openingDelimiterEnd + (lineEndingLength(at: openingDelimiterEnd, in: storage) ?? 0)
        var lineStart = rawStart

        while lineStart < storage.length {
            let lineEnd = endOfLine(startingAt: lineStart, in: storage)
            if fenceLineEnd(marker, from: lineStart, in: storage) == lineEnd {
                let bounds = Bounds(
                    rawYAML: storage.substring(with: NSRange(location: rawStart, length: lineStart - rawStart)),
                    lineEnding: openingEnding,
                    afterClosingDelimiter: storage.substring(from: lineEnd)
                )
                return isTOML ? .toml(bounds) : .closed(bounds)
            }

            guard let endingLength = lineEndingLength(at: lineEnd, in: storage) else {
                break
            }
            lineStart = lineEnd + endingLength
        }

        // An unclosed `+++` line is ordinary text, as it is to the editor's fence scanner.
        return isTOML
            ? .absent
            : .missingClosing(rawYAML: storage.substring(from: rawStart), lineEnding: openingEnding)
    }

    /// The end of a fence line that starts at `start` with `marker` followed only by spaces
    /// or tabs: the index of its line terminator or the end of `storage`, else `nil`.
    static func fenceLineEnd(_ marker: String, from start: Int, in storage: NSString) -> Int? {
        guard start + 3 <= storage.length,
              storage.substring(with: NSRange(location: start, length: 3)) == marker
        else {
            return nil
        }
        var index = start + 3
        while index < storage.length {
            let character = storage.character(at: index)
            if isNewline(character) { return index }
            guard character == 32 || character == 9 else { return nil }
            index += 1
        }
        return index
    }

    static func orderedKeys(in rawYAML: String, mapping: [String: Any]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for line in linesWithoutTerminators(rawYAML) {
            guard let key = topLevelKey(in: line), mapping.keys.contains(key), !seen.contains(key) else {
                continue
            }
            ordered.append(key)
            seen.insert(key)
        }

        for key in mapping.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }

        return ordered
    }

    static func frontmatterValue(for key: String, yamlValue: Any?, rawValue: String?) -> FrontmatterValue {
        if let value = yamlValue as? Bool {
            return .bool(value)
        }

        if let values = yamlValue as? [Any] {
            if let scalarValues = scalarStrings(from: values) {
                return .stringList(scalarValues)
            }
            return .raw(rawValue ?? "")
        }

        if let values = yamlValue as? [String] {
            return .stringList(values)
        }

        if key == "date" {
            return .date(rawValue ?? yamlValue.map { String(describing: $0) } ?? "")
        }

        if key == "tags" {
            if let rawValue {
                return .stringList(splitTags(rawValue))
            }
            return .stringList([])
        }

        if key == "draft", let rawValue {
            switch rawValue.lowercased() {
            case "true":
                return .bool(true)
            case "false":
                return .bool(false)
            default:
                break
            }
        }

        if let value = yamlValue as? String {
            return .string(value)
        }

        return .raw(rawValue ?? "")
    }

    static func scalarStrings(from values: [Any]) -> [String]? {
        var scalarValues: [String] = []
        for value in values {
            switch value {
            case let value as String:
                scalarValues.append(value)
            case let value as Bool:
                scalarValues.append(value ? "true" : "false")
            case let value as Int:
                scalarValues.append(String(value))
            case let value as Double:
                scalarValues.append(String(value))
            case let value as Float:
                scalarValues.append(String(value))
            default:
                return nil
            }
        }
        return scalarValues
    }
}
