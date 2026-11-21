import Foundation
import SwiftTreeSitter

extension MarkdownSyntaxParser {
    static let tsxHighlightQuerySource = """
    [
      "as"
      "async"
      "await"
      "break"
      "case"
      "catch"
      "class"
      "const"
      "continue"
      "debugger"
      "default"
      "delete"
      "do"
      "else"
      "export"
      "extends"
      "finally"
      "for"
      "from"
      "function"
      "if"
      "import"
      "in"
      "instanceof"
      "let"
      "new"
      "of"
      "return"
      "switch"
      "throw"
      "try"
      "typeof"
      "var"
      "void"
      "while"
      "with"
      "yield"
      "abstract"
      "declare"
      "enum"
      "implements"
      "interface"
      "keyof"
      "namespace"
      "private"
      "protected"
      "public"
      "readonly"
      "override"
      "satisfies"
      "type"
    ] @keyword
    (string) @string
    (template_string) @string
    (jsx_opening_element
      name: [(identifier) (jsx_namespace_name)] @tag)
    (jsx_closing_element
      name: [(identifier) (jsx_namespace_name)] @tag)
    (jsx_self_closing_element
      name: [(identifier) (jsx_namespace_name)] @tag)
    (jsx_attribute
      (property_identifier) @attribute)
    [
      "<"
      ">"
      "</"
      "/>"
      "{"
      "}"
      "="
    ] @punctuation
    """

    func appendMDXTokens(
        from root: Node,
        in source: String,
        canParseTSX: Bool,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        let excludedRanges = MDXRangeSet(tokens.compactMap { token -> NSRange? in
            if token.kind == .codeBlock || token.kind == .frontmatter {
                return token.range
            }
            return nil
        })

        guard canParseTSX else {
            appendMDXSourceFallbackTokens(in: source, excluding: excludedRanges, to: &tokens)
            return
        }

        // An HTML block is parsed whole, so the line pass must not parse its lines again.
        var htmlBlockRanges: [NSRange] = []
        appendMDXHTMLBlockRanges(from: root, to: &htmlBlockRanges)
        for range in htmlBlockRanges {
            appendTSXTokens(
                in: (source as NSString).substring(with: range),
                baseLocation: range.location,
                fallbackRange: range,
                to: &tokens
            )
        }
        let lineTSXRanges = appendMDXLineTSXTokens(
            in: source,
            excluding: excludedRanges.union(htmlBlockRanges),
            to: &tokens
        )
        appendMDXHTMLTokens(from: root, excludingInlineRanges: MDXRangeSet(lineTSXRanges), to: &tokens)
    }

    func appendMDXHTMLBlockRanges(from node: Node, to ranges: inout [NSRange]) {
        switch node.nodeType {
        case "html_block":
            ranges.append(nsRange(for: node))
            return

        case "inline", "fenced_code_block", "indented_code_block", "minus_metadata", "plus_metadata":
            return

        default:
            break
        }

        for index in 0 ..< node.childCount {
            if let child = node.child(at: index) {
                appendMDXHTMLBlockRanges(from: child, to: &ranges)
            }
        }
    }

    func appendMDXHTMLTokens(
        from node: Node,
        excludingInlineRanges excludedInlineRanges: MDXRangeSet,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        switch node.nodeType {
        case "inline":
            appendMDXInlineHTMLTokens(from: node, excluding: excludedInlineRanges, to: &tokens)
            return

        case "html_block", "fenced_code_block", "indented_code_block", "minus_metadata", "plus_metadata":
            return

        default:
            break
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendMDXHTMLTokens(from: child, excludingInlineRanges: excludedInlineRanges, to: &tokens)
        }
    }

    func appendMDXInlineHTMLTokens(
        from inlineNode: Node,
        excluding excludedRanges: MDXRangeSet,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        guard
            let inlineSource = inlineNode.text,
            !inlineSource.isEmpty,
            let tree = inlineParser.parse(inlineSource),
            let root = tree.rootNode
        else {
            return
        }

        appendMDXInlineHTMLTokens(
            from: root,
            baseLocation: nsRange(for: inlineNode).location,
            excluding: excludedRanges,
            to: &tokens
        )
    }

    func appendMDXInlineHTMLTokens(
        from node: Node,
        baseLocation: Int,
        excluding excludedRanges: MDXRangeSet,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        if node.nodeType == "html_inline" || node.nodeType == "html_tag" {
            let fallbackRange = nsRange(for: node, offset: baseLocation)
            guard !excludedRanges.intersects(fallbackRange) else {
                return
            }

            appendTSXTokens(
                in: node.text ?? "",
                baseLocation: baseLocation + nsRange(for: node).location,
                fallbackRange: fallbackRange,
                to: &tokens
            )
            return
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendMDXInlineHTMLTokens(
                from: child,
                baseLocation: baseLocation,
                excluding: excludedRanges,
                to: &tokens
            )
        }
    }

    @discardableResult
    func appendMDXLineTSXTokens(
        in source: String,
        excluding excludedRanges: MDXRangeSet,
        to tokens: inout [MarkdownSyntaxToken]
    ) -> [NSRange] {
        let nsSource = source as NSString
        var location = 0
        var parsedRanges: [NSRange] = []

        while location < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsSource.substring(with: lineRange)
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMDXLine = isMDXESMLine(trimmed) || isMDXJSXLine(trimmed)

            if isMDXLine, !excludedRanges.intersects(lineRange) {
                appendTSXTokens(
                    in: rawLine,
                    baseLocation: lineRange.location,
                    fallbackRange: lineRange,
                    to: &tokens
                )
                parsedRanges.append(lineRange)
            }

            location = NSMaxRange(lineRange)
        }

        return parsedRanges
    }

    func appendTSXTokens(
        in source: String,
        baseLocation: Int,
        fallbackRange: NSRange,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        guard
            !source.isEmpty,
            let resources = tsxResources(),
            let tree = resources.parser.parse(source),
            let root = tree.rootNode
        else {
            tokens.append(MarkdownSyntaxToken(kind: .mdxSource, range: fallbackRange))
            return
        }

        let cursor = resources.query.execute(node: root, in: tree)
        for highlight in cursor.highlights() {
            guard let kind = MarkdownSyntaxToken.Kind(tsxCaptureName: highlight.name) else {
                continue
            }

            tokens.append(MarkdownSyntaxToken(
                kind: kind,
                range: NSRange(
                    location: baseLocation + highlight.range.location,
                    length: highlight.range.length
                )
            ))
        }
    }

    func appendMDXSourceFallbackTokens(
        in source: String,
        excluding excludedRanges: MDXRangeSet,
        to tokens: inout [MarkdownSyntaxToken]
    ) {
        let nsSource = source as NSString
        var location = 0

        while location < nsSource.length {
            let lineRange = nsSource.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsSource.substring(with: lineRange)
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isMDXESMLine(trimmed) || isMDXJSXLine(trimmed), !excludedRanges.intersects(lineRange) {
                tokens.append(MarkdownSyntaxToken(kind: .mdxSource, range: lineRange))
            }

            location = NSMaxRange(lineRange)
        }
    }

    func isMDXESMLine(_ line: String) -> Bool {
        line.hasPrefix("import ") || line.hasPrefix("export ")
    }

    func isMDXJSXLine(_ line: String) -> Bool {
        guard line.hasPrefix("<") else {
            return false
        }

        let nameStart = line.dropFirst().drop { $0 == "/" }.first
        return nameStart?.isLetter == true
    }
}

private extension MarkdownSyntaxToken.Kind {
    init?(tsxCaptureName: String) {
        switch tsxCaptureName {
        case "keyword":
            self = .tsxKeyword
        case "string", "string.special":
            self = .tsxString
        case "tag":
            self = .tsxTag
        case "attribute":
            self = .tsxAttribute
        case "punctuation":
            self = .tsxPunctuation
        default:
            return nil
        }
    }
}

/// Disjoint sorted ranges, so an intersection test is a binary search instead of a scan
/// of every range for every line.
struct MDXRangeSet {
    private let ranges: [NSRange]

    init(_ ranges: [NSRange]) {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        self.ranges = merged
    }

    func union(_ other: [NSRange]) -> MDXRangeSet {
        MDXRangeSet(ranges + other)
    }

    func intersects(_ range: NSRange) -> Bool {
        guard range.length > 0 else {
            return false
        }
        // The first range that ends after `range` starts is the only candidate.
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= range.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].location < NSMaxRange(range)
    }
}
