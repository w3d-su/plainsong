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
    public let rawYAML: String
    public let fields: [FrontmatterField]
    public let lineEnding: String

    public var fieldValues: [String: FrontmatterValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
    }

    public init(rawYAML: String, fields: [FrontmatterField], lineEnding: String) {
        self.rawYAML = rawYAML
        self.fields = fields
        self.lineEnding = lineEnding
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
        }
    }

    public static func updating(_ text: String, key: String, value: FrontmatterValue) -> String? {
        switch scanFences(in: text) {
        case let .closed(bounds):
            guard parseClosedBlock(bounds).error == nil else { return nil }
            let updatedYAML = replacing(rawYAML: bounds.rawYAML, key: key, value: value, lineEnding: bounds.lineEnding)
            return "---" + bounds.lineEnding + updatedYAML + "---" + bounds.afterClosingDelimiter
        case .absent, .missingClosing:
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
    }

    enum ParseError: Error, CustomStringConvertible {
        case notMapping

        var description: String {
            "Frontmatter must be a YAML mapping."
        }
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

    static func scanFences(in text: String) -> FenceScan {
        let storage = text as NSString
        guard storage.length >= 3,
              storage.substring(with: NSRange(location: 0, length: 3)) == "---"
        else {
            return .absent
        }

        let openingDelimiterEnd = 3
        guard openingDelimiterEnd == storage.length ||
            isNewline(storage.character(at: openingDelimiterEnd))
        else {
            return .absent
        }

        let openingEnding = lineEnding(at: openingDelimiterEnd, in: storage) ?? "\n"
        let rawStart = openingDelimiterEnd + (lineEndingLength(at: openingDelimiterEnd, in: storage) ?? 0)
        var lineStart = rawStart

        while lineStart < storage.length {
            let lineEnd = endOfLine(startingAt: lineStart, in: storage)
            let lineText = storage.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            if lineText.trimmingCharacters(in: .whitespaces) == "---" {
                let rawYAML = storage.substring(with: NSRange(location: rawStart, length: lineStart - rawStart))
                let afterClosingDelimiter = storage.substring(from: lineEnd)
                return .closed(Bounds(
                    rawYAML: rawYAML,
                    lineEnding: openingEnding,
                    afterClosingDelimiter: afterClosingDelimiter
                ))
            }

            guard let endingLength = lineEndingLength(at: lineEnd, in: storage) else {
                break
            }
            lineStart = lineEnd + endingLength
        }

        return .missingClosing(rawYAML: storage.substring(from: rawStart), lineEnding: openingEnding)
    }

    static func loadMapping(from rawYAML: String) throws -> [String: Any] {
        let trimmedYAML = rawYAML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedYAML.isEmpty else { return [:] }

        let loaded = try Yams.load(yaml: rawYAML)
        if let mapping = loaded as? [String: Any] {
            return mapping
        }

        if let mapping = loaded as? [AnyHashable: Any] {
            var stringMapping: [String: Any] = [:]
            for (key, value) in mapping {
                guard let stringKey = key as? String else {
                    throw ParseError.notMapping
                }
                stringMapping[stringKey] = value
            }
            return stringMapping
        }

        throw ParseError.notMapping
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

    static func replacing(
        rawYAML: String,
        key: String,
        value: FrontmatterValue,
        lineEnding: String
    ) -> String {
        var lines = linesWithoutTerminators(rawYAML)
        if hasLineTerminatorSuffix(rawYAML), lines.last == "" {
            lines.removeLast()
        }

        let replacementLines = formattedLines(key: key, value: value)
        if let startIndex = lines.firstIndex(where: { topLevelKey(in: $0) == key }) {
            let endIndex = valueSpanEndIndex(startingAt: startIndex, in: lines)
            lines.replaceSubrange(startIndex ..< endIndex, with: replacementLines)
        } else {
            lines.append(contentsOf: replacementLines)
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    static func formattedLines(key: String, value: FrontmatterValue) -> [String] {
        switch value {
        case let .bool(value):
            return ["\(key): \(value ? "true" : "false")"]
        case let .date(value):
            return ["\(key): \(value)"]
        case let .string(value):
            return ["\(key): \(formattedScalar(value))"]
        case let .raw(value):
            return ["\(key): \(value)"]
        case let .stringList(values):
            if values.isEmpty {
                return ["\(key): []"]
            }
            return ["\(key):"] + values.map { "  - \(formattedScalar($0))" }
        }
    }

    static func formattedScalar(_ value: String) -> String {
        if value.isEmpty {
            return #""""#
        }

        let lowercased = value.lowercased()
        let needsQuoting = value != value.trimmingCharacters(in: .whitespaces) ||
            value.contains(":") ||
            value.contains("#") ||
            value.contains("[") ||
            value.contains("]") ||
            value.contains("{") ||
            value.contains("}") ||
            value.contains("\n") ||
            ["true", "false", "null", "~"].contains(lowercased)

        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
