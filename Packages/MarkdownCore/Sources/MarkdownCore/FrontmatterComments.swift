import CYaml
import Foundation

extension Frontmatter {
    /// YAML discards comments on load. Use the same LibYAML scanner as Yams to
    /// distinguish them from hashes inside quoted, plain, or block scalar values.
    static func preserveComments(
        in replacedLines: ArraySlice<String>, rawYAML: String, replacement: inout [String]
    ) throws {
        guard replacedLines.contains(where: { $0.contains("#") }) else { return }

        try Array(rawYAML.utf8).withUnsafeBufferPointer { bytes in
            var parser = yaml_parser_t()
            try withUnsafeMutablePointer(to: &parser) { parser in
                guard yaml_parser_initialize(parser) != 0 else { throw ParseError.unreadableTokens }
                defer { yaml_parser_delete(parser) }
                // LibYAML retains both addresses until scanning finishes.
                yaml_parser_set_input_string(parser, bytes.baseAddress, bytes.count)
                try appendComments(in: replacedLines, parser: parser, replacement: &replacement)
            }
        }
    }

    private static func appendComments(
        in replacedLines: ArraySlice<String>, parser: UnsafeMutablePointer<yaml_parser_t>, replacement: inout [String]
    ) throws {
        var token = yaml_token_t()
        defer { yaml_token_delete(&token) }
        for lineIndex in replacedLines.indices {
            let line = replacedLines[lineIndex]
            let scalars = line.unicodeScalars
            for (column, index) in scalars.indices.enumerated() where scalars[index] == "#" {
                let position = (lineIndex, column)
                while (token.end_mark.line, token.end_mark.column) <= position {
                    guard token.type != YAML_STREAM_END_TOKEN else { break }
                    yaml_token_delete(&token)
                    guard yaml_parser_scan(parser, &token) != 0 else { throw ParseError.unreadableTokens }
                }
                let isBlockHeader = token.type == YAML_SCALAR_TOKEN && token.start_mark.line == lineIndex
                    && [YAML_LITERAL_SCALAR_STYLE, YAML_FOLDED_SCALAR_STYLE].contains(token.data.scalar.style)
                guard isBlockHeader || position < (token.start_mark.line, token.start_mark.column)
                    || token.type == YAML_STREAM_END_TOKEN else { continue }

                let before = scalars[..<index]
                let comment = String(scalars[index...])
                if lineIndex == replacedLines.startIndex {
                    let padding = before.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
                    replacement[0] += String(String.UnicodeScalarView(padding)) + comment
                } else {
                    let indentation = before.prefix { $0 == " " || $0 == "\t" }
                    replacement.append(String(indentation) + comment)
                }
                break
            }
        }
    }
}
