import Foundation
import SwiftTreeSitter

extension MarkdownSyntaxParser {
    func appendInlineCandidates(
        from inlineNode: Node,
        baseLocation: Int,
        to candidates: inout [WYSIWYGFoldCandidate]
    ) {
        guard
            let inlineSource = inlineNode.text,
            !inlineSource.isEmpty,
            let tree = inlineParser.parse(inlineSource),
            let root = tree.rootNode
        else {
            return
        }

        appendInlineCandidates(
            from: root,
            inlineSource: inlineSource,
            baseLocation: baseLocation + nsRange(for: inlineNode).location,
            to: &candidates
        )
    }

    func appendInlineCandidates(
        from node: Node,
        inlineSource: String,
        baseLocation: Int,
        to candidates: inout [WYSIWYGFoldCandidate]
    ) {
        if let candidate = inlineCandidate(from: node, inlineSource: inlineSource, baseLocation: baseLocation) {
            candidates.append(candidate)
        }

        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            appendInlineCandidates(from: child, inlineSource: inlineSource, baseLocation: baseLocation, to: &candidates)
        }
    }

    func inlineCandidate(
        from node: Node,
        inlineSource: String,
        baseLocation: Int
    ) -> WYSIWYGFoldCandidate? {
        switch node.nodeType {
        case "strong_emphasis":
            delimiterCandidate(
                kind: .strong,
                markers: ["**", "__"],
                from: node,
                inlineSource: inlineSource,
                baseLocation: baseLocation
            )
        case "emphasis":
            delimiterCandidate(
                kind: .emphasis,
                markers: ["*", "_"],
                from: node,
                inlineSource: inlineSource,
                baseLocation: baseLocation
            )
        case "strikethrough":
            delimiterCandidate(
                kind: .strikethrough,
                markers: ["~~"],
                from: node,
                inlineSource: inlineSource,
                baseLocation: baseLocation
            )
        case "code_span":
            codeSpanCandidate(from: node, baseLocation: baseLocation)
        case "inline_link":
            inlineLinkCandidate(from: node, inlineSource: inlineSource, baseLocation: baseLocation)
        default:
            nil
        }
    }

    func delimiterCandidate(
        kind: WYSIWYGFoldRegion.Kind,
        markers: [String],
        from node: Node,
        inlineSource: String,
        baseLocation: Int
    ) -> WYSIWYGFoldCandidate? {
        let storage = inlineSource as NSString
        let localRange = nsRange(for: node)
        guard NSMaxRange(localRange) <= storage.length else {
            return nil
        }

        let text = storage.substring(with: localRange)
        guard let marker = markers.first(where: { marker in
            text.hasPrefix(marker) && text.hasSuffix(marker) && text.utf16.count > marker.utf16.count * 2
        }) else {
            return nil
        }

        let markerLength = marker.utf16.count
        let openingRange = NSRange(location: localRange.location, length: markerLength)
        let closingRange = NSRange(location: NSMaxRange(localRange) - markerLength, length: markerLength)
        let contentRange = NSRange(
            location: NSMaxRange(openingRange) + baseLocation,
            length: max(0, closingRange.location - NSMaxRange(openingRange))
        )
        return WYSIWYGFoldCandidate(
            kind: kind,
            sourceRange: localRange.offset(by: baseLocation),
            contentRange: contentRange,
            revealRange: localRange.offset(by: baseLocation),
            foldRanges: [openingRange.offset(by: baseLocation), closingRange.offset(by: baseLocation)]
        )
    }

    func codeSpanCandidate(from node: Node, baseLocation: Int) -> WYSIWYGFoldCandidate? {
        let delimiterRanges = childRanges(named: "code_span_delimiter", in: node)
        guard let openingRange = delimiterRanges.first, let closingRange = delimiterRanges.last,
              openingRange != closingRange
        else {
            return nil
        }

        let contentRange = NSRange(
            location: NSMaxRange(openingRange) + baseLocation,
            length: max(0, closingRange.location - NSMaxRange(openingRange))
        )
        return WYSIWYGFoldCandidate(
            kind: .inlineCode,
            sourceRange: nsRange(for: node, offset: baseLocation),
            contentRange: contentRange,
            revealRange: nsRange(for: node, offset: baseLocation),
            foldRanges: [openingRange.offset(by: baseLocation), closingRange.offset(by: baseLocation)]
        )
    }

    func inlineLinkCandidate(
        from node: Node,
        inlineSource: String,
        baseLocation: Int
    ) -> WYSIWYGFoldCandidate? {
        guard let linkTextNode = firstChild(named: "link_text", in: node) else {
            return nil
        }

        let sourceRange = nsRange(for: node, offset: baseLocation)
        let linkTextRange = nsRange(for: linkTextNode)
        let contentRange = linkContentRange(from: linkTextRange, inlineSource: inlineSource)
            .offset(by: baseLocation)
        let foldRanges = foldRanges(around: contentRange, in: sourceRange)
        guard !foldRanges.isEmpty else {
            return nil
        }

        return WYSIWYGFoldCandidate(
            kind: .link,
            sourceRange: sourceRange,
            contentRange: contentRange,
            revealRange: sourceRange,
            foldRanges: foldRanges
        )
    }

    func linkContentRange(from linkTextRange: NSRange, inlineSource: String) -> NSRange {
        let storage = inlineSource as NSString
        var location = linkTextRange.location
        var end = NSMaxRange(linkTextRange)

        if location < end, storage.character(at: location) == 91 {
            location += 1
        }
        if end > location, storage.character(at: end - 1) == 93 {
            end -= 1
        }

        return NSRange(location: location, length: max(0, end - location))
    }

    func foldRanges(around contentRange: NSRange, in sourceRange: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        if contentRange.location > sourceRange.location {
            ranges.append(NSRange(location: sourceRange.location, length: contentRange.location - sourceRange.location))
        }
        if NSMaxRange(contentRange) < NSMaxRange(sourceRange) {
            ranges.append(NSRange(
                location: NSMaxRange(contentRange),
                length: NSMaxRange(sourceRange) - NSMaxRange(contentRange)
            ))
        }
        return ranges
    }

    func childRanges(named childType: String, in node: Node) -> [NSRange] {
        var ranges: [NSRange] = []
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            if child.nodeType == childType {
                ranges.append(nsRange(for: child))
            }
        }
        return ranges
    }

    func firstChild(named childType: String, in node: Node) -> Node? {
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            if child.nodeType == childType {
                return child
            }
        }
        return nil
    }
}
