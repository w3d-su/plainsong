import Foundation
import MarkdownCore
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterTSXFixed
import TreeSitterYAMLFixed

/// Shared Markdown and MDX parser for Mac and iOS source mode.
///
/// Ranges are absolute UTF-16 offsets into the `String` passed to that call.
/// `tokens(in:fileKind:visibleRange:)` adds the expanded viewport's location.
/// Callers see document coordinates, with that location included in every range.
/// SwiftTreeSitter 0.10 `Parser.parse(_:)` submits that string as UTF-16LE
/// (`TSInputEncodingUTF16LE`). `nsRange(for:)` divides that UTF-16LE byte range
/// by two and returns UTF-16 code units.
///
/// One instance owns the mutable tree-sitter parsers. Keep it on a single actor.
/// `tokens(in:fileKind:)` still skips inline markup above `inlineParsingLimit`
/// UTF-8 bytes. Visible-range parsing does not. That cutoff is not an iOS
/// visible-range performance result.
public final class MarkdownSyntaxParser {
    /// Full block parsing stays enabled for large documents. Inline sub-parsing is
    /// deferred until visible-range plumbing lands so 1 MB edits do not saturate CPU.
    public static let inlineParsingLimit = 250_000
    public static let visibleHighlightMinimumLength = 4096

    let markdownParser: Parser
    let inlineParser: Parser
    private var cachedTSXParser: Parser?
    private var cachedTSXHighlightQuery: Query?
    private var cachedYAMLParser: Parser?

    public init() throws {
        markdownParser = Parser()
        inlineParser = Parser()

        try markdownParser.setLanguage(Language(language: tree_sitter_markdown()))
        try inlineParser.setLanguage(Language(language: tree_sitter_markdown_inline()))
    }

    public func tokens(in source: String, fileKind: FileKind) -> [MarkdownSyntaxToken] {
        tokens(
            in: source,
            fileKind: fileKind,
            parsesInlineMarkup: source.utf8.count <= Self.inlineParsingLimit
        )
    }

    public func tokens(in source: String, fileKind: FileKind,
                       visibleRange requestedRange: NSRange) -> [MarkdownSyntaxToken]
    {
        let range = Self.visibleHighlightRange(in: source, requestedRange: requestedRange)
        return tokens(in: source, fileKind: fileKind, expandedVisibleRange: range)
    }

    /// Parses coverage the caller already expanded, avoiding a second full-prefix scan.
    public func tokens(
        in source: String,
        fileKind: FileKind,
        expandedVisibleRange range: NSRange
    ) -> [MarkdownSyntaxToken] {
        guard let fragment = source.fragment(in: range) else {
            return []
        }

        return tokens(in: fragment, fileKind: fileKind, parsesInlineMarkup: true)
            .map { token in
                MarkdownSyntaxToken(
                    kind: token.kind,
                    range: NSRange(location: token.range.location + range.location, length: token.range.length)
                )
            }
    }

    private func tokens(
        in source: String,
        fileKind: FileKind,
        parsesInlineMarkup: Bool
    ) -> [MarkdownSyntaxToken] {
        guard
            !source.isEmpty,
            let tree = markdownParser.parse(source),
            let root = tree.rootNode
        else {
            return []
        }

        var tokens: [MarkdownSyntaxToken] = []
        appendBlockTokens(from: root, parsesInlineMarkup: parsesInlineMarkup, to: &tokens)

        if fileKind == .mdx {
            appendMDXTokens(
                from: root,
                in: source,
                canParseTSX: parsesInlineMarkup,
                to: &tokens
            )
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

    func tsxResources() -> (parser: Parser, query: Query)? {
        if let cachedTSXParser, let cachedTSXHighlightQuery {
            return (cachedTSXParser, cachedTSXHighlightQuery)
        }

        let parser = Parser()
        let language = Language(language: tree_sitter_tsx())
        guard
            (try? parser.setLanguage(language)) != nil,
            let query = try? Query(
                language: language,
                data: Self.tsxHighlightQuerySource.data(using: .utf8) ?? Data()
            )
        else {
            return nil
        }

        cachedTSXParser = parser
        cachedTSXHighlightQuery = query
        return (parser, query)
    }

    private func yamlParserForHighlighting() -> Parser? {
        if let cachedYAMLParser {
            return cachedYAMLParser
        }

        let parser = Parser()
        guard (try? parser.setLanguage(Language(language: tree_sitter_yaml()))) != nil else {
            return nil
        }

        cachedYAMLParser = parser
        return parser
    }
}

extension MarkdownSyntaxParser {
    /// Expands viewport ranges to whole lines plus lightweight Markdown context.
    ///
    /// This intentionally keeps tokenization visible-range-first: callers do not parse
    /// the full document on the edit path. The only document-wide work here is
    /// `MarkdownFenceScanner`'s linear line scan (frontmatter and fence state), so
    /// visible code-block lines keep their Markdown context.
    public static func visibleHighlightRange(in source: String, requestedRange: NSRange) -> NSRange {
        let nsSource = source as NSString
        guard nsSource.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let clampedRange = requestedRange.clamped(toLength: nsSource.length)
        let lineRange = lineRangeCovering(clampedRange, in: nsSource)
        let start = lineRange.location
        var end = NSMaxRange(lineRange)

        if end - start < visibleHighlightMinimumLength {
            let targetEnd = min(nsSource.length, start + visibleHighlightMinimumLength)
            let seed = min(max(targetEnd, 0), nsSource.length - 1)
            end = max(end, NSMaxRange(nsSource.lineRange(for: NSRange(location: seed, length: 0))))
        }

        let context = MarkdownFenceScanner.contextRange(
            in: source,
            expanding: NSRange(location: start, length: max(0, end - start))
        )
        return context.clamped(toLength: nsSource.length)
    }

    private static func lineRangeCovering(_ range: NSRange, in source: NSString) -> NSRange {
        let fallbackLocation = min(range.location, max(0, source.length - 1))
        let startLocation = min(max(fallbackLocation, 0), source.length - 1)
        let lastLocation = min(max(NSMaxRange(range) - 1, startLocation), source.length - 1)
        let startLine = source.lineRange(for: NSRange(location: startLocation, length: 0))
        let endLine = source.lineRange(for: NSRange(location: lastLocation, length: 0))
        return NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
    }
}

extension MarkdownSyntaxParser {
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

        case "block_quote_marker":
            tokens.append(MarkdownSyntaxToken(kind: .quoteMarker, range: nsRange(for: node)))

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
            let yamlParser = yamlParserForHighlighting(),
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

private extension String {
    func fragment(in range: NSRange) -> String? {
        guard let stringRange = Range(range, in: self) else {
            return nil
        }
        return String(self[stringRange])
    }
}
