import Foundation
import MarkdownCore
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterTSXFixed
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
        case tsxKeyword
        case tsxString
        case tsxTag
        case tsxAttribute
        case tsxPunctuation
    }

    var kind: Kind
    var range: NSRange
}

final class MarkdownSyntaxParser {
    /// Full block parsing stays enabled for large documents. Inline sub-parsing is
    /// deferred until visible-range plumbing lands so 1 MB edits do not saturate CPU.
    static let inlineParsingLimit = 250_000
    static let visibleHighlightMinimumLength = 4096

    private let markdownParser: Parser
    let inlineParser: Parser
    private var cachedTSXParser: Parser?
    private var cachedTSXHighlightQuery: Query?
    private var cachedYAMLParser: Parser?

    init() throws {
        markdownParser = Parser()
        inlineParser = Parser()

        try markdownParser.setLanguage(Language(language: tree_sitter_markdown()))
        try inlineParser.setLanguage(Language(language: tree_sitter_markdown_inline()))
    }

    func tokens(in source: String, fileKind: FileKind) -> [MarkdownSyntaxToken] {
        tokens(
            in: source,
            fileKind: fileKind,
            parsesInlineMarkup: source.utf8.count <= Self.inlineParsingLimit
        )
    }

    func tokens(in source: String, fileKind: FileKind, visibleRange requestedRange: NSRange) -> [MarkdownSyntaxToken] {
        let range = Self.visibleHighlightRange(in: source, requestedRange: requestedRange)
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
    /// the full document on the edit path. The only document-wide work here is a linear
    /// fence-state scan so visible code-block lines keep their Markdown context.
    static func visibleHighlightRange(in source: String, requestedRange: NSRange) -> NSRange {
        let nsSource = source as NSString
        guard nsSource.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let clampedRange = requestedRange.clamped(toLength: nsSource.length)
        let lineRange = lineRangeCovering(clampedRange, in: nsSource)
        var start = lineRange.location
        var end = NSMaxRange(lineRange)

        if end - start < visibleHighlightMinimumLength {
            let targetEnd = min(nsSource.length, start + visibleHighlightMinimumLength)
            let seed = min(max(targetEnd, 0), nsSource.length - 1)
            end = max(end, NSMaxRange(nsSource.lineRange(for: NSRange(location: seed, length: 0))))
        }

        (start, end) = expandFrontmatterContext(in: nsSource, start: start, end: end)
        (start, end) = expandFencedCodeContext(in: nsSource, start: start, end: end)

        return NSRange(location: start, length: max(0, end - start)).clamped(toLength: nsSource.length)
    }

    private static func lineRangeCovering(_ range: NSRange, in source: NSString) -> NSRange {
        let fallbackLocation = min(range.location, max(0, source.length - 1))
        let startLocation = min(max(fallbackLocation, 0), source.length - 1)
        let lastLocation = min(max(NSMaxRange(range) - 1, startLocation), source.length - 1)
        let startLine = source.lineRange(for: NSRange(location: startLocation, length: 0))
        let endLine = source.lineRange(for: NSRange(location: lastLocation, length: 0))
        return NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
    }

    private static func expandFrontmatterContext(in source: NSString, start: Int, end: Int) -> (Int, Int) {
        let firstLine = source.lineRange(for: NSRange(location: 0, length: 0))
        let marker = source.substring(with: firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker == "---" || marker == "+++" else {
            return (start, end)
        }

        var cursor = NSMaxRange(firstLine)
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == marker {
                let frontmatterRange = NSRange(location: 0, length: NSMaxRange(lineRange))
                let requested = NSRange(location: start, length: max(0, end - start))
                guard NSIntersectionRange(frontmatterRange, requested).length > 0 else {
                    return (start, end)
                }
                return (0, max(end, NSMaxRange(lineRange)))
            }

            let next = NSMaxRange(lineRange)
            guard next > cursor else { break }
            cursor = next
        }

        return (start, end)
    }

    private static func expandFencedCodeContext(in source: NSString, start: Int, end: Int) -> (Int, Int) {
        let originalStart = start
        var expandedStart = start
        var expandedEnd = end
        var cursor = 0
        var isInsideFence = false
        var openFenceRange: NSRange?

        while cursor < originalStart {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            if isFenceLine(source.substring(with: lineRange)) {
                if isInsideFence {
                    isInsideFence = false
                    openFenceRange = nil
                } else {
                    isInsideFence = true
                    openFenceRange = lineRange
                }
            }

            let next = NSMaxRange(lineRange)
            guard next > cursor else { break }
            cursor = next
        }

        if isInsideFence, let openFenceRange {
            expandedStart = openFenceRange.location
        }

        cursor = originalStart
        var insideAtEnd = isInsideFence
        while cursor < expandedEnd {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            if isFenceLine(source.substring(with: lineRange)) {
                insideAtEnd.toggle()
            }

            let next = NSMaxRange(lineRange)
            guard next > cursor else { break }
            cursor = next
        }

        if insideAtEnd {
            while cursor < source.length {
                let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
                expandedEnd = NSMaxRange(lineRange)
                if isFenceLine(source.substring(with: lineRange)) {
                    break
                }

                let next = NSMaxRange(lineRange)
                guard next > cursor else { break }
                cursor = next
            }
        }

        return (expandedStart, expandedEnd)
    }

    private static func isFenceLine(_ line: String) -> Bool {
        var cursor = line.startIndex
        var leadingSpaces = 0
        while cursor < line.endIndex, line[cursor] == " " {
            leadingSpaces += 1
            cursor = line.index(after: cursor)
        }

        guard leadingSpaces <= 3, cursor < line.endIndex else {
            return false
        }

        let marker = line[cursor]
        guard marker == "`" || marker == "~" else {
            return false
        }

        var markerCount = 0
        while cursor < line.endIndex, line[cursor] == marker {
            markerCount += 1
            cursor = line.index(after: cursor)
        }

        return markerCount >= 3
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
