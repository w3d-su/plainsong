import Foundation
import MarkdownCore
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterYAMLFixed

struct MarkdownSyntaxToken {
    enum Kind: Equatable {
        case frontmatter
        case frontmatterKey
        case headingMarker
        case headingText(level: Int)
        case listMarker
        case codeBlock
        case codeFenceMarker
        case codeFenceInfo
        case inlineCode
        case strong
        case emphasis
        case linkText
        case linkDestination
        case tableHeader
        case tableDelimiter
        case tablePipe
        case mdxSource
    }

    var kind: Kind
    var range: NSRange
}

final class MarkdownSyntaxParser {
    /// Full block parsing stays enabled for large documents. Inline sub-parsing is
    /// deferred until visible-range plumbing lands so 1 MB edits do not saturate CPU.
    static let inlineParsingLimit = 250_000

    private let markdownParser: Parser
    private let inlineParser: Parser
    private let yamlParser: Parser

    init() throws {
        markdownParser = Parser()
        inlineParser = Parser()
        yamlParser = Parser()

        try markdownParser.setLanguage(Language(language: tree_sitter_markdown()))
        try inlineParser.setLanguage(Language(language: tree_sitter_markdown_inline()))
        try yamlParser.setLanguage(Language(language: tree_sitter_yaml()))
    }

    func tokens(in source: String, fileKind: FileKind) -> [MarkdownSyntaxToken] {
        guard
            !source.isEmpty,
            let tree = markdownParser.parse(source),
            let root = tree.rootNode
        else {
            return []
        }

        var tokens: [MarkdownSyntaxToken] = []
        let parsesInlineMarkup = source.utf8.count <= Self.inlineParsingLimit
        appendBlockTokens(from: root, parsesInlineMarkup: parsesInlineMarkup, to: &tokens)

        if fileKind == .mdx {
            appendMDXSourceTokens(in: source, to: &tokens)
        }

        return tokens
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length > rhs.range.length
            }
    }
}

private extension MarkdownSyntaxParser {
    func appendBlockTokens(
        from node: Node,
        parsesInlineMarkup: Bool,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        let type = node.nodeType ?? ""

        switch type {
        case "minus_metadata", "plus_metadata":
            let range = nsRange(for: node)
            tokens.append(MarkdownSyntaxToken(kind: .frontmatter, range: range))
            appendYAMLTokens(from: node, to: &tokens)
            return

        case "fenced_code_block", "indented_code_block":
            tokens.append(MarkdownSyntaxToken(kind: .codeBlock, range: nsRange(for: node)))
            appendCodeBlockChildTokens(from: node, to: &tokens)
            return

        case "pipe_table":
            appendTableTokens(from: node, to: &tokens)
            return

        case "atx_heading", "setext_heading":
            appendHeadingTokens(from: node, to: &tokens)

        case "list_marker_plus",
             "list_marker_minus",
             "list_marker_star",
             "list_marker_dot",
             "list_marker_parenthesis",
             "task_list_marker_checked",
             "task_list_marker_unchecked":
            tokens.append(MarkdownSyntaxToken(kind: .listMarker, range: nsRange(for: node)))

        case "inline":
            if parsesInlineMarkup {
                appendInlineTokens(from: node, to: &tokens)
            }
            return

        default:
            break
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendBlockTokens(from: child, parsesInlineMarkup: parsesInlineMarkup, to: &tokens)
        }
    }

    func appendHeadingTokens(from node: Node, to tokens: inout [MarkdownSyntaxToken]) {
        let level = headingLevel(from: node)

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }

            let type = child.nodeType ?? ""
            if type.hasPrefix("atx_h") && type.hasSuffix("_marker") || type.hasPrefix("setext_h") {
                tokens.append(MarkdownSyntaxToken(kind: .headingMarker, range: nsRange(for: child)))
            }
        }

        if let content = node.child(byFieldName: "heading_content") {
            tokens.append(MarkdownSyntaxToken(kind: .headingText(level: level), range: nsRange(for: content)))
        }
    }

    func appendCodeBlockChildTokens(from node: Node, to tokens: inout [MarkdownSyntaxToken]) {
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }

            switch child.nodeType {
            case "fenced_code_block_delimiter":
                tokens.append(MarkdownSyntaxToken(kind: .codeFenceMarker, range: nsRange(for: child)))
            case "info_string":
                tokens.append(MarkdownSyntaxToken(kind: .codeFenceInfo, range: nsRange(for: child)))
            default:
                continue
            }
        }
    }

    func appendInlineTokens(from node: Node, to tokens: inout [MarkdownSyntaxToken]) {
        guard
            let inlineSource = node.text,
            !inlineSource.isEmpty,
            let tree = inlineParser.parse(inlineSource),
            let root = tree.rootNode
        else {
            return
        }

        let baseLocation = nsRange(for: node).location
        appendInlineTokens(from: root, baseLocation: baseLocation, to: &tokens)
    }

    func appendInlineTokens(
        from node: Node,
        baseLocation: Int,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        let kind: MarkdownSyntaxToken.Kind? = switch node.nodeType {
        case "code_span":
            .inlineCode
        case "strong_emphasis":
            .strong
        case "emphasis":
            .emphasis
        case "link_text", "image_description", "link_label":
            .linkText
        case "link_destination", "uri_autolink", "email_autolink":
            .linkDestination
        default:
            nil
        }

        if let kind {
            tokens.append(MarkdownSyntaxToken(kind: kind, range: nsRange(for: node, offset: baseLocation)))
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendInlineTokens(from: child, baseLocation: baseLocation, to: &tokens)
        }
    }

    func appendYAMLTokens(
        from node: Node,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        let metadataRange = nsRange(for: node)
        guard
            let metadataText = node.text,
            let yamlRange = frontmatterBody(in: metadataText)
        else {
            return
        }

        let yamlSource = String(metadataText[yamlRange])
        guard
            let tree = yamlParser.parse(yamlSource),
            let root = tree.rootNode
        else {
            return
        }

        let baseLocation = metadataRange.location + metadataText.utf16.distance(
            from: metadataText.utf16.startIndex,
            to: yamlRange.lowerBound.samePosition(in: metadataText.utf16) ?? metadataText.utf16.startIndex
        )
        appendYAMLTokens(from: root, baseLocation: baseLocation, to: &tokens)
    }

    func appendYAMLTokens(
        from node: Node,
        baseLocation: Int,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        if node.nodeType == "block_mapping_pair", let keyNode = node.child(byFieldName: "key") {
            tokens.append(MarkdownSyntaxToken(
                kind: .frontmatterKey,
                range: nsRange(for: keyNode, offset: baseLocation)
            ))
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendYAMLTokens(from: child, baseLocation: baseLocation, to: &tokens)
        }
    }

    func appendTableTokens(from node: Node, to tokens: inout [MarkdownSyntaxToken]) {
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }

            switch child.nodeType {
            case "pipe_table_header":
                tokens.append(MarkdownSyntaxToken(kind: .tableHeader, range: nsRange(for: child)))
                appendTablePipeTokens(from: child, to: &tokens)
            case "pipe_table_delimiter_row":
                tokens.append(MarkdownSyntaxToken(kind: .tableDelimiter, range: nsRange(for: child)))
            case "pipe_table_row":
                appendTablePipeTokens(from: child, to: &tokens)
            default:
                continue
            }
        }
    }

    func appendTablePipeTokens(from row: Node, to tokens: inout [MarkdownSyntaxToken]) {
        for index in 0 ..< row.childCount {
            guard let child = row.child(at: index), child.nodeType == "|" else {
                continue
            }
            tokens.append(MarkdownSyntaxToken(kind: .tablePipe, range: nsRange(for: child)))
        }
    }

    func appendMDXSourceTokens(in source: String, to tokens: inout [MarkdownSyntaxToken]) {
        let nsSource = source as NSString
        var location = 0

        while location < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsSource.substring(with: lineRange)
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isImportOrExport = trimmed.hasPrefix("import ") || trimmed.hasPrefix("export ")
            let isComponentLine = trimmed.hasPrefix("<") && trimmed.dropFirst().first?.isUppercase == true

            if isImportOrExport || isComponentLine {
                tokens.append(MarkdownSyntaxToken(kind: .mdxSource, range: lineRange))
            }

            location = NSMaxRange(lineRange)
        }
    }

    func headingLevel(from node: Node) -> Int {
        for index in 0 ..< node.childCount {
            guard let type = node.child(at: index)?.nodeType else {
                continue
            }

            if type.hasPrefix("atx_h"), let level = type.dropFirst(5).first?.wholeNumberValue {
                return min(max(level, 1), 6)
            }

            if type == "setext_h1_underline" {
                return 1
            }

            if type == "setext_h2_underline" {
                return 2
            }
        }

        return 1
    }

    func frontmatterBody(in metadataText: String) -> Range<String.Index>? {
        guard
            let firstNewline = metadataText.firstIndex(where: \.isNewline),
            let closingLine = metadataText.range(of: "\n---", options: .backwards)
            ?? metadataText.range(of: "\n+++", options: .backwards),
            firstNewline < closingLine.lowerBound
        else {
            return nil
        }

        return metadataText.index(after: firstNewline) ..< closingLine.lowerBound
    }

    func nsRange(for node: Node, offset: Int = 0) -> NSRange {
        let bytes = node.byteRange
        let location = Int(bytes.lowerBound / 2) + offset
        let length = Int((bytes.upperBound - bytes.lowerBound) / 2)
        return NSRange(location: location, length: length)
    }
}
