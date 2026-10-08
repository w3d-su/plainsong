import Foundation
import MarkdownCore

/// Pure fold and image-region model. Mac presentation maps these ranges onto
/// AppKit attributes; this type has no color, font, or view.
public struct WYSIWYGFoldPlan: Equatable {
    public let visibleRange: NSRange
    public let regions: [WYSIWYGFoldRegion]
    /// Syntax-only image metadata. Presentation deliberately ignores these regions until
    /// the later image-thumbnail render-policy gates are complete.
    public let imageRegions: [MarkdownInlineImageRegion]
    public let linkFoldingEnabled: Bool

    public init(
        visibleRange: NSRange,
        regions: [WYSIWYGFoldRegion],
        imageRegions: [MarkdownInlineImageRegion] = [],
        linkFoldingEnabled: Bool = false
    ) {
        self.visibleRange = visibleRange
        self.regions = regions
        self.imageRegions = imageRegions
        self.linkFoldingEnabled = linkFoldingEnabled
    }

    public var foldedRanges: [NSRange] {
        Self.mergedRanges(
            regions
                .filter { !$0.isRevealed }
                .flatMap(\.foldRanges)
        )
    }

    public var revealedRegions: [WYSIWYGFoldRegion] {
        regions.filter(\.isRevealed)
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sortedRanges = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.location != rhs.location {
                    return lhs.location < rhs.location
                }
                return lhs.length < rhs.length
            }

        var merged: [NSRange] = []
        for range in sortedRanges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            let lastEnd = NSMaxRange(last)
            if range.location <= lastEnd {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(lastEnd, NSMaxRange(range)) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

public struct WYSIWYGFoldRegion: Equatable {
    public enum Kind: Equatable, Hashable {
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        case inlineCode
        case link
    }

    public let kind: Kind
    public let sourceRange: NSRange
    public let contentRange: NSRange
    public let revealRange: NSRange
    public let foldRanges: [NSRange]
    public let isRevealed: Bool

    public init(
        kind: Kind,
        sourceRange: NSRange,
        contentRange: NSRange,
        revealRange: NSRange,
        foldRanges: [NSRange],
        isRevealed: Bool
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.contentRange = contentRange
        self.revealRange = revealRange
        self.foldRanges = foldRanges
        self.isRevealed = isRevealed
    }
}

struct WYSIWYGFoldCandidate: Equatable {
    let kind: WYSIWYGFoldRegion.Kind
    let sourceRange: NSRange
    let contentRange: NSRange
    let revealRange: NSRange
    let foldRanges: [NSRange]
}

enum WYSIWYGFoldResolver {
    static func resolve(
        candidates: [WYSIWYGFoldCandidate],
        visibleRange: NSRange,
        selection: NSRange,
        linkFoldingEnabled: Bool = false
    ) -> WYSIWYGFoldPlan {
        let regions = candidates.map { candidate in
            WYSIWYGFoldRegion(
                kind: candidate.kind,
                sourceRange: candidate.sourceRange,
                contentRange: candidate.contentRange,
                revealRange: candidate.revealRange,
                foldRanges: candidate.foldRanges,
                isRevealed: selection.touches(candidate.revealRange)
            )
        }

        return WYSIWYGFoldPlan(
            visibleRange: visibleRange,
            regions: regions,
            linkFoldingEnabled: linkFoldingEnabled
        )
    }
}

private extension NSRange {
    func touches(_ other: NSRange) -> Bool {
        if length == 0 {
            return location >= other.location && location < NSMaxRange(other)
        }
        return NSIntersectionRange(self, other).length > 0
    }
}
