import Foundation
import MarkdownCore
import SwiftTreeSitter

/// Compatibility wrapper for tests and focused fold/reveal callers.
///
/// Production presentation uses `MarkdownSyntaxParser.foldPlan(...)` through
/// `MarkdownHighlightService` so visible-range highlighting and folding share a
/// parser actor instead of creating a parser on each edit.
final class WYSIWYGFoldParser {
    private let parser: MarkdownSyntaxParser

    init() throws {
        parser = try MarkdownSyntaxParser()
    }

    init(parser: MarkdownSyntaxParser) {
        self.parser = parser
    }

    func foldPlan(
        in source: String,
        fileKind: FileKind,
        visibleRange requestedRange: NSRange,
        selection: NSRange
    ) -> WYSIWYGFoldPlan {
        parser.foldPlan(
            in: source,
            fileKind: fileKind,
            visibleRange: requestedRange,
            selection: selection
        )
    }
}

extension MarkdownSyntaxParser {
    func visibleTokensAndFoldPlan(
        in source: String,
        fileKind: FileKind,
        visibleRange requestedRange: NSRange,
        selection: NSRange
    ) -> (visibleRange: NSRange, tokens: [MarkdownSyntaxToken], foldPlan: WYSIWYGFoldPlan) {
        let sourceLength = (source as NSString).length
        guard sourceLength > 0 else {
            let emptyRange = NSRange(location: 0, length: 0)
            return (emptyRange, [], WYSIWYGFoldPlan(visibleRange: emptyRange, regions: []))
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
            return (visibleRange, [], WYSIWYGFoldPlan(visibleRange: visibleRange, regions: []))
        }

        var tokens: [MarkdownSyntaxToken] = []
        appendBlockTokens(from: root, parsesInlineMarkup: true, to: &tokens)

        if fileKind == .mdx {
            appendMDXTokens(
                from: root,
                in: fragment,
                canParseTSX: true,
                to: &tokens
            )
        }

        let absoluteTokens = tokens
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { token in
                MarkdownSyntaxToken(
                    kind: token.kind,
                    range: NSRange(
                        location: token.range.location + visibleRange.location,
                        length: token.range.length
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length > rhs.range.length
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

        let foldPlan = WYSIWYGFoldResolver.resolve(
            candidates: filteredCandidates,
            visibleRange: visibleRange,
            selection: selection.clamped(toLength: sourceLength)
        )

        return (visibleRange, absoluteTokens, foldPlan)
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

extension MarkdownSyntaxParser {
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
