import Foundation

public enum EditorReplaceSourceConstruction {
    public static func enclosingRange(of ranges: [NSRange]) -> NSRange? {
        guard let validated = validatedRanges(ranges),
              let first = validated.first, let last = validated.last
        else { return nil }
        return NSRange(location: first.lowerBound, length: last.upperBound - first.lowerBound)
    }

    public static func projectedUTF16Length(
        sourceLength: Int,
        ranges: [NSRange],
        replacementUTF16Length: Int
    ) -> Int? {
        guard replacementUTF16Length >= 0,
              let validated = validatedRanges(ranges, lengthBound: sourceLength)
        else { return nil }
        var removed = 0
        for range in validated {
            let (next, overflow) = removed.addingReportingOverflow(range.count)
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
        replacedSlice(
            source,
            enclosing: NSRange(location: 0, length: (source as NSString).length),
            ranges: ranges,
            replacement: replacement
        )
    }

    /// Builds only the local replacement text for R0 candidate B1's one native edit.
    /// Ranges use absolute source UTF-16 offsets; gaps inside `enclosing` are preserved.
    /// Empty ranges return the unchanged slice. Invalid or escaping ranges fail closed.
    public static func replacedSlice(
        _ source: String,
        enclosing: NSRange,
        ranges: [NSRange],
        replacement: String
    ) -> String? {
        let nsSource = source as NSString
        guard let enclosingEnd = EditorReplacePlanning.rangeEnd(enclosing),
              enclosingEnd <= nsSource.length,
              let validated = validatedRanges(ranges, lengthBound: enclosingEnd),
              validated.first.map({ $0.lowerBound >= enclosing.location }) ?? true
        else { return nil }
        // Validation proves 0 <= enclosing.location <= every endpoint <= enclosingEnd.
        // These subtractions cannot underflow, overflow, or escape the local slice.
        let localRanges = validated.map {
            ($0.lowerBound - enclosing.location) ..< ($0.upperBound - enclosing.location)
        }
        return constructSource(
            nsSource.substring(with: enclosing) as NSString,
            ranges: localRanges,
            replacement: replacement
        )
    }

    private static func constructSource(
        _ source: NSString,
        ranges: [Range<Int>],
        replacement: String
    ) -> String {
        var cursor = 0
        var parts: [String] = []
        for range in ranges {
            if range.lowerBound > cursor {
                parts.append(source.substring(with: NSRange(
                    location: cursor,
                    length: range.lowerBound - cursor
                )))
            }
            parts.append(replacement)
            cursor = range.upperBound
        }
        if cursor < source.length {
            parts.append(source.substring(from: cursor))
        }
        return parts.joined()
    }

    /// Maps a pre-write UTF-16 offset through a batch of differing ranges.
    public static func mapUTF16Offset(
        _ offset: Int,
        through ranges: [NSRange],
        replacementUTF16Length: Int
    ) -> Int? {
        guard offset >= 0, replacementUTF16Length >= 0,
              let validated = validatedRanges(ranges)
        else { return nil }
        var mapped = offset
        for range in validated {
            if offset < range.lowerBound {
                return mapped
            }
            let (delta, deltaOverflow) = replacementUTF16Length.subtractingReportingOverflow(
                range.count
            )
            if deltaOverflow { return nil }
            if offset < range.upperBound {
                // `mapped` already includes every preceding edit. Remove the offset's
                // distance into this match before advancing to the replacement end.
                let (start, startOverflow) = mapped.subtractingReportingOverflow(offset - range.lowerBound)
                if startOverflow { return nil }
                let (result, overflow) = start.addingReportingOverflow(
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

    /// Validate the entire list before consumers may return early (e.g. offset mapping).
    private static func validatedRanges(
        _ ranges: [NSRange],
        lengthBound: Int? = nil
    ) -> [Range<Int>]? {
        if let lengthBound, lengthBound < 0 { return nil }
        var previousEnd = 0
        var validated: [Range<Int>] = []
        validated.reserveCapacity(ranges.count)
        for range in ranges {
            guard range.location >= previousEnd,
                  let end = EditorReplacePlanning.rangeEnd(range),
                  lengthBound.map({ end <= $0 }) ?? true
            else { return nil }
            validated.append(range.location ..< end)
            previousEnd = end
        }
        return validated
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
    /// Distribute the remainder into the earliest intervals (250 => 3...150, 152...250).
    /// This pure schedule is independent of WorkspaceKit's candidate-progress stride.
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
