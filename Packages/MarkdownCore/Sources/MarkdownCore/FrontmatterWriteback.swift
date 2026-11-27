import Foundation
import Yams

/// Inspector writeback: one key of a closed YAML block is rewritten as text, then the new
/// block is parsed again and accepted only if it still reads back as the requested value.
extension Frontmatter {
    enum ParseError: Error, CustomStringConvertible {
        case notMapping
        case unreadableTokens

        var description: String {
            switch self {
            case .notMapping: "Frontmatter must be a YAML mapping."
            case .unreadableTokens: "Could not read YAML tokens while preserving comments."
            }
        }
    }

    struct ParsedMapping {
        let root: Node?
        let values: [String: Any]

        init(yaml: String) throws {
            if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                root = nil
                values = [:]
            } else {
                root = try Yams.compose(yaml: yaml)
                values = try Frontmatter.mappingValues(from: root?.any)
            }
        }
    }

    private static func mappingValues(from loaded: Any?) throws -> [String: Any] {
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

    static func replacing(
        rawYAML: String,
        original: ParsedMapping,
        key: String,
        value: FrontmatterValue,
        lineEnding: String
    ) throws -> String? {
        let sourceLines = yamlSourceLines(in: rawYAML)
        let lines = sourceLines.map(String.init)
        if original.values[key] != nil {
            // A line resembling a key can itself be part of a multiline scalar.
            guard let mark = original.root?.mapping?.first(where: { $0.key.scalar?.string == key })?.key.mark,
                  mark.column == 1, lines.indices.contains(mark.line - 1),
                  let span = topLevelKeySpan(in: lines[mark.line - 1]), span.key == key else { return nil }
            let startIndex = mark.line - 1
            // Keep the source's spelling of the key (`"title"`, `'title'`), so the edit
            // replaces that entry instead of appending a second, duplicate `title`.
            let endIndex = valueSpanEndIndex(startingAt: startIndex, in: lines)
            var replacementLines = try formattedLines(
                keyToken: span.keyToken,
                value: value,
                quotesDate: span.hasQuotedInlineValue
            )
            try preserveComments(
                in: lines[startIndex ..< endIndex], rawYAML: rawYAML, replacement: &replacementLines
            )
            let range = sourceLines[startIndex].startIndex ..< sourceLines[endIndex - 1].endIndex
            return rawYAML.replacingCharacters(in: range, with: replacementLines.joined(separator: lineEnding))
        }

        let added = try formattedLines(keyToken: formattedKey(key), value: value, quotesDate: false)
        let separator = rawYAML.isEmpty || sourceLines.last?.isEmpty == true ? "" : lineEnding
        return rawYAML + separator + added.joined(separator: lineEnding) + lineEnding
    }

    /// Whether `updatedYAML` still parses, has exactly the original keys (plus `key` when it
    /// was appended), and loads `key` as `value`. This refuses writebacks the line-based
    /// rewrite cannot express, such as a key spelling it does not recognize.
    static func writebackReadsBack(
        _ updatedYAML: String,
        original: ParsedMapping,
        key: String,
        value: FrontmatterValue
    ) -> Bool {
        guard let updated = try? ParsedMapping(yaml: updatedYAML),
              Set(updated.values.keys) == Set(original.values.keys).union([key]),
              let written = updated.values[key]
        else {
            return false
        }

        switch value {
        case let .string(expected):
            return (written as? String) == expected
        case let .bool(expected):
            return (written as? Bool) == expected
        case let .stringList(expected):
            guard let items = written as? [Any] else { return false }
            return items.compactMap { $0 as? String } == expected && items.count == expected.count
        case let .date(expected):
            return updated.root?[key]?.scalar?.string == expected && !(written is NSNull)
        case .raw:
            return true
        }
    }

    static func formattedLines(
        keyToken: String,
        value: FrontmatterValue,
        quotesDate: Bool
    ) throws -> [String] {
        switch value {
        case let .bool(value):
            return ["\(keyToken): \(value ? "true" : "false")"]
        case let .date(value):
            // A date stays plain only when YAML reads it back as exactly this plain scalar
            // (`2026-06-16`, `2026-06-16T08:30:00Z`), so it keeps its type. Anything else,
            // and any date the source had quoted, is written as a quoted string.
            if !quotesDate, isPlainScalarRoundTrip(value) {
                return ["\(keyToken): \(value)"]
            }
            return try ["\(keyToken): \(formattedScalar(value))"]
        case let .string(value):
            return try ["\(keyToken): \(formattedScalar(value))"]
        case let .raw(value):
            return ["\(keyToken): \(value)"]
        case let .stringList(values):
            if values.isEmpty {
                return ["\(keyToken): []"]
            }
            return try ["\(keyToken):"] + values.map { try "  - \(formattedScalar($0))" }
        }
    }

    /// A key appended to the block: plain when it is an ordinary identifier, else quoted.
    static func formattedKey(_ key: String) throws -> String {
        let isPlainIdentifier = key.range(
            of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#,
            options: .regularExpression
        ) != nil
        return isPlainIdentifier ? key : try formattedScalar(key)
    }

    static func formattedScalar(_ value: String) throws -> String {
        // Quote strings explicitly so YAML implicit typing cannot turn form input into
        // booleans/numbers. LibYAML owns escaping, including newlines and control scalars.
        // Disable line wrapping to keep each localized field/list item on one source line.
        let node = Node.scalar(Node.Scalar(value, Tag(.str), .doubleQuoted))
        let yaml = try Yams.serialize(node: node, width: -1)
        return yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
    }

    /// Whether `key: value` composes to a single plain scalar whose text is `value`, so
    /// writing it unquoted cannot introduce a mapping, a sequence, a comment, an alias, a
    /// tag or a second line.
    static func isPlainScalarRoundTrip(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains(where: \.isNewline),
              value.trimmingCharacters(in: .whitespaces) == value,
              let node = try? Yams.compose(yaml: "key: \(value)\n"),
              let mapping = node.mapping,
              mapping.count == 1,
              let scalar = mapping.first?.value.scalar,
              scalar.style == .plain
        else {
            return false
        }
        return scalar.string == value
    }
}
