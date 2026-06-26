import Foundation
import MarkdownCore
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// Range-only WYSIWYG spike model. It intentionally does not apply attributes,
/// customize layout fragments, mutate source text, or connect to editor modes.
final class WYSIWYGFoldParser {
    private let markdownParser: Parser
    let inlineParser: Parser

    init() throws {
        markdownParser = Parser()
        inlineParser = Parser()

        try markdownParser.setLanguage(Language(language: tree_sitter_markdown()))
        try inlineParser.setLanguage(Language(language: tree_sitter_markdown_inline()))
    }

    func foldPlan(
        in source: String,
        fileKind _: FileKind,
        visibleRange requestedRange: NSRange,
        selection: NSRange
    ) -> WYSIWYGFoldPlan {
        let sourceLength = (source as NSString).length
        guard sourceLength > 0 else {
            return WYSIWYGFoldPlan(visibleRange: NSRange(location: 0, length: 0), regions: [])
        }

        let visibleRange = MarkdownSyntaxParser.visibleHighlightRange(
            in: source,
            requestedRange: requestedRange.clamped(toLength: sourceLength)
        )
        guard
            let fragment = source.fragment(in: visibleRange),
            let tree = markdownParser.parse(fragment),
            let root = tree.rootNode
        else {
            return WYSIWYGFoldPlan(visibleRange: visibleRange, regions: [])
        }

        var candidates: [WYSIWYGFoldCandidate] = []
        appendBlockCandidates(
            from: root,
            fragment: fragment,
            baseLocation: visibleRange.location,
            to: &candidates
        )

        let filteredCandidates = uniqueCandidates(candidates)
            .filter { $0.sourceRange.intersects(visibleRange) }
            .sorted { lhs, rhs in
                if lhs.sourceRange.location != rhs.sourceRange.location {
                    return lhs.sourceRange.location < rhs.sourceRange.location
                }
                return lhs.sourceRange.length > rhs.sourceRange.length
            }

        return WYSIWYGFoldResolver.resolve(
            candidates: filteredCandidates,
            visibleRange: visibleRange,
            selection: selection.clamped(toLength: sourceLength)
        )
    }

    private func uniqueCandidates(_ candidates: [WYSIWYGFoldCandidate]) -> [WYSIWYGFoldCandidate] {
        var unique: [WYSIWYGFoldCandidate] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }
}

extension WYSIWYGFoldParser {
    func appendBlockCandidates(
        from node: Node,
        fragment: String,
        baseLocation: Int,
        to candidates: inout [WYSIWYGFoldCandidate]
    ) {
        switch node.nodeType {
        case "minus_metadata", "plus_metadata", "fenced_code_block", "indented_code_block":
            return

        case "atx_heading", "setext_heading":
            if let candidate = headingCandidate(from: node, fragment: fragment, baseLocation: baseLocation) {
                candidates.append(candidate)
            }

        case "inline":
            appendInlineCandidates(from: node, baseLocation: baseLocation, to: &candidates)
            return

        default:
            break
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendBlockCandidates(from: child, fragment: fragment, baseLocation: baseLocation, to: &candidates)
        }
    }

    func headingCandidate(
        from node: Node,
        fragment: String,
        baseLocation: Int
    ) -> WYSIWYGFoldCandidate? {
        let localSourceRange = nsRange(for: node)
        let sourceRange = nsRange(for: node, offset: baseLocation)
        let level = headingLevel(from: node)
        let revealRange = (fragment as NSString)
            .lineRange(for: localSourceRange)
            .offset(by: baseLocation)

        let contentRange = node.child(byFieldName: "heading_content")
            .map { headingContentRange(for: $0, fragment: fragment, baseLocation: baseLocation) }
            ?? NSRange(location: NSMaxRange(sourceRange), length: 0)

        let foldRanges = headingFoldRanges(from: node, fragment: fragment, baseLocation: baseLocation)
        guard !foldRanges.isEmpty else {
            return nil
        }

        return WYSIWYGFoldCandidate(
            kind: .heading(level: level),
            sourceRange: sourceRange,
            contentRange: contentRange,
            revealRange: revealRange,
            foldRanges: foldRanges
        )
    }

    func headingContentRange(for node: Node, fragment: String, baseLocation: Int) -> NSRange {
        let storage = fragment as NSString
        var localRange = nsRange(for: node)

        while localRange.length > 0, NSMaxRange(localRange) <= storage.length {
            let character = storage.character(at: NSMaxRange(localRange) - 1)
            guard character == 10 || character == 13 else {
                break
            }
            localRange.length -= 1
        }

        return localRange.offset(by: baseLocation)
    }

    func headingFoldRanges(from node: Node, fragment: String, baseLocation: Int) -> [NSRange] {
        let storage = fragment as NSString
        var ranges: [NSRange] = []

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index), let type = child.nodeType else {
                continue
            }

            if type.hasPrefix("atx_h"), type.hasSuffix("_marker") {
                var markerRange = nsRange(for: child)
                if NSMaxRange(markerRange) < storage.length,
                   storage.character(at: NSMaxRange(markerRange)) == 32 {
                    markerRange.length += 1
                }
                ranges.append(markerRange.offset(by: baseLocation))
            } else if type.hasPrefix("setext_h") {
                ranges.append(nsRange(for: child, offset: baseLocation))
            }
        }

        return ranges
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

    func nsRange(for node: Node, offset: Int = 0) -> NSRange {
        let bytes = node.byteRange
        let location = Int(bytes.lowerBound / 2) + offset
        let length = Int((bytes.upperBound - bytes.lowerBound) / 2)
        return NSRange(location: location, length: length)
    }
}

extension NSRange {
    func offset(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }

    func intersects(_ other: NSRange) -> Bool {
        NSIntersectionRange(self, other).length > 0
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
