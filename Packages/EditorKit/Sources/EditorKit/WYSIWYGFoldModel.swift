import Foundation

struct WYSIWYGFoldPlan: Equatable {
    let visibleRange: NSRange
    let regions: [WYSIWYGFoldRegion]

    var foldedRanges: [NSRange] {
        Self.mergedRanges(
            regions
                .filter { !$0.isRevealed }
                .flatMap(\.foldRanges)
        )
    }

    var revealedRegions: [WYSIWYGFoldRegion] {
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

struct WYSIWYGFoldRegion: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        case inlineCode
        case link
    }

    let kind: Kind
    let sourceRange: NSRange
    let contentRange: NSRange
    let revealRange: NSRange
    let foldRanges: [NSRange]
    let isRevealed: Bool
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
        selection: NSRange
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

        return WYSIWYGFoldPlan(visibleRange: visibleRange, regions: regions)
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
