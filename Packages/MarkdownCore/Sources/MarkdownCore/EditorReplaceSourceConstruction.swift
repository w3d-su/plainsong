import Foundation

public enum EditorReplaceSourceConstruction {
    public static func enclosingRange(of ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.first else { return nil }
        var previousEnd = first.location
        var finalEnd = first.location
        for range in ranges {
            guard range.location >= previousEnd,
                  let end = EditorReplacePlanning.rangeEnd(range)
            else {
                return nil
            }
            previousEnd = end
            finalEnd = end
        }
        return NSRange(location: first.location, length: finalEnd - first.location)
    }

    public static func projectedUTF16Length(
        sourceLength: Int,
        ranges: [NSRange],
        replacementUTF16Length: Int
    ) -> Int? {
        guard sourceLength >= 0, replacementUTF16Length >= 0 else { return nil }
        var removed = 0
        var previousEnd = 0
        for range in ranges {
            guard range.location >= previousEnd,
                  let end = EditorReplacePlanning.rangeEnd(range),
                  end <= sourceLength
            else {
                return nil
            }
            previousEnd = end
            let (next, overflow) = removed.addingReportingOverflow(range.length)
            if overflow { return nil }
            removed = next
        }
        guard removed <= sourceLength else { return nil }
        let afterRemoval = sourceLength - removed
        let (added, addedOverflow) = ranges.count.multipliedReportingOverflow(
            by: replacementUTF16Length
        )
        if addedOverflow { return nil }
        let (projected, projectedOverflow) = afterRemoval.addingReportingOverflow(added)
        if projectedOverflow { return nil }
        if projected > sourceLength {
            let growth = projected - sourceLength
            if growth > EditorReplaceLimits.maximumGrowthUTF16 {
                return nil
            }
        }
        return projected
    }

    public static func replacedSource(
        _ source: String,
        ranges: [NSRange],
        replacement: String
    ) -> String? {
        let nsSource = source as NSString
        let length = nsSource.length
        var cursor = 0
        var parts: [String] = []
        parts.reserveCapacity(ranges.count * 2 + 1)
        for range in ranges {
            guard range.location >= cursor,
                  let end = EditorReplacePlanning.rangeEnd(range),
                  end <= length
            else {
                return nil
            }
            if range.location > cursor {
                parts.append(nsSource.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                )))
            }
            parts.append(replacement)
            cursor = end
        }
        if cursor < length {
            parts.append(nsSource.substring(from: cursor))
        }
        return parts.joined()
    }

    /// Maps a pre-write UTF-16 offset through a batch of differing ranges.
    public static func mapUTF16Offset(
        _ offset: Int,
        through ranges: [NSRange],
        replacementUTF16Length: Int
    ) -> Int? {
        guard offset >= 0, replacementUTF16Length >= 0 else { return nil }
        var mapped = offset
        var previousEnd = 0
        for range in ranges {
            guard range.location >= previousEnd,
                  let end = EditorReplacePlanning.rangeEnd(range)
            else {
                return nil
            }
            previousEnd = end
            if offset < range.location {
                return mapped
            }
            let (delta, deltaOverflow) = replacementUTF16Length.subtractingReportingOverflow(
                range.length
            )
            if deltaOverflow { return nil }
            if offset < end {
                let (result, overflow) = range.location.addingReportingOverflow(
                    replacementUTF16Length
                )
                return overflow ? nil : result
            }
            let (next, overflow) = mapped.addingReportingOverflow(delta)
            if overflow { return nil }
            mapped = next
        }
        return mapped
    }

    /// Whether an off-main plan must check cancellation before doing more work.
    ///
    /// Cancellation cadence and visible progress cadence are intentionally separate:
    /// coalescing progress to 100 updates must never create a cancellation blind spot.
    public static func shouldCheckCancellation(
        plannedMatchesSinceLastCheck: Int,
        copiedUTF16SinceLastCheck: Int
    ) -> Bool {
        plannedMatchesSinceLastCheck >= EditorReplaceLimits.cancellationMatchChunk
            || copiedUTF16SinceLastCheck >= EditorReplaceLimits.cancellationUTF16Chunk
    }

    /// At most 100 monotonically increasing visible-progress milestones, including `total`.
    public static func progressUpdateMilestones(totalMatchCount: Int) -> [Int] {
        guard totalMatchCount > 0 else { return [] }
        let updateCount = min(
            totalMatchCount,
            EditorReplaceLimits.maximumProgressUpdates
        )
        return (1 ... updateCount).map { index in
            let quotient = totalMatchCount / updateCount
            let remainder = totalMatchCount % updateCount
            return index * quotient + min(index, remainder)
        }
    }
}
