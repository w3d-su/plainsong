import Foundation

public enum EditorReplaceBatchPreparationFailure: Equatable, Sendable, Error {
    case cancelled
    case invalidPlan(EditorReplacePlanRefusal)
}

/// Deterministic checkpoint evidence. Counts cover the entire preparation.
public struct EditorReplacePreparationChunk: Equatable, Sendable {
    public let plannedMatchCount: Int
    public let copiedUTF16Count: Int
}

public struct EditorReplacePreparationProgress: Equatable, Sendable {
    public let completedMatchCount: Int
    public let totalMatchCount: Int
}

/// Everything required for B1's one minimal-enclosing native insertion.
/// The caller owns source/authority fencing and runs preparation off-main.
public struct EditorReplacePreparedBatch: Equatable, Sendable {
    public let plan: EditorReplaceBatchPlan
    public let replacementSlice: String?
    public let sourceSnapshot: String
    public let expectedSource: String
    public let postSelection: NSRange
}

public enum EditorReplaceBatchPreparation {
    public static func prepare(
        session: EditorFindSession,
        source: String,
        replacement: String,
        selection: NSRange,
        isCancelled: @escaping () -> Bool = { false },
        onChunk: @escaping (EditorReplacePreparationChunk) -> Void = { _ in },
        progress: (EditorReplacePreparationProgress) -> Void = { _ in }
    ) -> Result<EditorReplacePreparedBatch, EditorReplaceBatchPreparationFailure> {
        var work = EditorReplacePreparationWork(
            isCancelled: isCancelled,
            onChunk: onChunk
        )
        do {
            try work.checkpoint()
            let plan = try work.plan(session: session, source: source, replacement: replacement, progress: progress)
            guard !plan.isNoOp, let enclosing = plan.enclosingRange else {
                try work.checkpoint()
                progress(EditorReplacePreparationProgress(
                    completedMatchCount: session.total,
                    totalMatchCount: session.total
                ))
                try work.checkCancellation()
                return .success(EditorReplacePreparedBatch(
                    plan: plan, replacementSlice: nil, sourceSnapshot: source, expectedSource: source,
                    postSelection: selection
                ))
            }
            let postSelection = try work.mappedSelection(
                session: session,
                plan: plan,
                selection: selection,
                sourceLength: (source as NSString).length
            )
            let slice = try work.buildSlice(source: source, plan: plan, enclosing: enclosing)
            var expected = ""
            try work.reserveUTF16Capacity(plan.projectedUTF16Length, for: &expected)
            let nsSource = source as NSString
            try work.append(nsSource, range: NSRange(location: 0, length: enclosing.location), to: &expected)
            try work.append(
                slice as NSString,
                range: NSRange(location: 0, length: (slice as NSString).length),
                to: &expected
            )
            let end = enclosing.location + enclosing.length // Validated by plan().
            try work.append(nsSource, range: NSRange(location: end, length: nsSource.length - end), to: &expected)
            try work.checkpoint()
            progress(EditorReplacePreparationProgress(
                completedMatchCount: session.total,
                totalMatchCount: session.total
            ))
            try work.checkCancellation()
            return .success(EditorReplacePreparedBatch(
                plan: plan, replacementSlice: slice, sourceSnapshot: source, expectedSource: expected,
                postSelection: postSelection
            ))
        } catch let failure as EditorReplaceBatchPreparationFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidPlan(.projectedLengthOverflow))
        }
    }
}

private struct EditorReplacePreparationWork {
    let isCancelled: () -> Bool
    let onChunk: (EditorReplacePreparationChunk) -> Void
    var plannedMatchCount = 0
    var copiedUTF16Count = 0
    var matchesSinceCheck = 0
    var copiedSinceCheck = 0

    mutating func checkpoint() throws {
        onChunk(EditorReplacePreparationChunk(plannedMatchCount: plannedMatchCount, copiedUTF16Count: copiedUTF16Count))
        try checkCancellation()
        matchesSinceCheck = 0
        copiedSinceCheck = 0
    }

    func checkCancellation() throws {
        if isCancelled() {
            throw EditorReplaceBatchPreparationFailure.cancelled
        }
    }

    mutating func plan(
        session: EditorFindSession,
        source: String,
        replacement: String,
        progress: (EditorReplacePreparationProgress) -> Void
    ) throws -> EditorReplaceBatchPlan {
        let validity = EditorReplacePlanning.validateReplacement(replacement)
        guard validity == .valid else { throw invalid(.invalidReplacement(validity)) }
        guard !session.isTruncated else { throw invalid(.truncatedSession) }
        guard session.total > 0 else { throw invalid(.emptySession) }
        guard session.total <= EditorFindLimits.retainedMatchCeiling else { throw invalid(.truncatedSession) }
        let nsSource = source as NSString
        let replacementLength = (replacement as NSString).length
        let milestones = EditorReplaceSourceConstruction.progressUpdateMilestones(totalMatchCount: session.total)
        var milestoneIndex = 0
        var allRanges: [NSRange] = []
        var differing: [NSRange] = []
        allRanges.reserveCapacity(session.total)
        differing.reserveCapacity(session.total)
        var previousEnd = 0
        var removedLength = 0
        for match in session.matches {
            let range = match.range
            guard range.length > 0, range.location >= previousEnd,
                  let end = EditorReplacePlanning.rangeEnd(range), end <= nsSource.length,
                  isScalarBoundary(range.location, in: nsSource), isScalarBoundary(end, in: nsSource)
            else { throw invalid(.noCurrentMatch) }
            previousEnd = end
            allRanges.append(range)
            // Unequal lengths are already non-identical. Literal comparison never
            // scans more than the bounded replacement value for equal lengths.
            if range.length != replacementLength || nsSource
                .compare(replacement, options: .literal, range: range) != .orderedSame
            {
                differing.append(range)
                let (next, overflow) = removedLength.addingReportingOverflow(range.length)
                guard !overflow else { throw invalid(.projectedLengthOverflow) }
                removedLength = next
            }
            plannedMatchCount += 1
            matchesSinceCheck += 1
            if matchesSinceCheck == EditorReplaceLimits.cancellationMatchChunk {
                try checkpoint()
            }
            if milestoneIndex < milestones.count, plannedMatchCount == milestones[milestoneIndex] {
                // Completion is emitted only after all construction has drained.
                if plannedMatchCount < session.total {
                    progress(EditorReplacePreparationProgress(
                        completedMatchCount: plannedMatchCount,
                        totalMatchCount: session.total
                    ))
                    try checkCancellation()
                }
                milestoneIndex += 1
            }
        }
        try checkpoint()
        // All checked growth math precedes text-output allocation and construction.
        let (addedLength, addedOverflow) = differing.count.multipliedReportingOverflow(by: replacementLength)
        let (projected, projectedOverflow) = (nsSource.length - removedLength).addingReportingOverflow(addedLength)
        guard !addedOverflow, !projectedOverflow,
              projected <= nsSource.length || projected - nsSource.length <= EditorReplaceLimits.maximumGrowthUTF16
        else { throw invalid(.projectedLengthOverflow) }
        let enclosing: NSRange? = if let first = differing.first, let last = differing.last {
            NSRange(location: first.location, length: last.location + last.length - first.location)
        } else {
            nil
        }
        return EditorReplaceBatchPlan(
            query: session.query, replacement: replacement, allRanges: allRanges,
            differingRanges: differing, changedCount: differing.count, totalCount: session.total,
            enclosingRange: enclosing, projectedUTF16Length: projected
        )
    }

    mutating func mappedSelection(
        session: EditorFindSession, plan: EditorReplaceBatchPlan, selection: NSRange, sourceLength: Int
    ) throws -> NSRange {
        guard let selectionEnd = EditorReplacePlanning.rangeEnd(selection),
              selectionEnd <= sourceLength
        else { throw invalid(.noCurrentMatch) }
        let currentEnd = session.currentMatch.flatMap { EditorReplacePlanning.rangeEnd($0.range) }
        let anchor = currentEnd ?? selection.location
        let replacementLength = (plan.replacement as NSString).length
        var mapped = anchor
        for range in plan.differingRanges {
            // A current match owns its trailing boundary, including adjacent hits.
            if let currentEnd, range.location >= currentEnd {
                break
            }
            if anchor < range.location {
                break
            }
            if anchor < range.location + range.length {
                mapped = mapped - (anchor - range.location) + replacementLength
                break
            }
            let (next, overflow) = mapped.addingReportingOverflow(replacementLength - range.length)
            guard !overflow else { throw invalid(.projectedLengthOverflow) }
            mapped = next
            matchesSinceCheck += 1
            if matchesSinceCheck == EditorReplaceLimits.cancellationMatchChunk {
                try checkpoint()
            }
        }
        try checkpoint()
        return NSRange(location: min(max(0, mapped), plan.projectedUTF16Length), length: 0)
    }

    mutating func buildSlice(source: String, plan: EditorReplaceBatchPlan, enclosing: NSRange) throws -> String {
        let nsSource = source as NSString
        let nsReplacement = plan.replacement as NSString
        var result = ""
        let untouchedLength = nsSource.length - enclosing.length
        try reserveUTF16Capacity(plan.projectedUTF16Length - untouchedLength, for: &result)
        var cursor = enclosing.location
        for range in plan.differingRanges {
            try append(nsSource, range: NSRange(location: cursor, length: range.location - cursor), to: &result)
            try append(nsReplacement, range: NSRange(location: 0, length: nsReplacement.length), to: &result)
            cursor = range.location + range.length
            matchesSinceCheck += 1
            if matchesSinceCheck == EditorReplaceLimits.cancellationMatchChunk {
                try checkpoint()
            }
        }
        try append(
            nsSource,
            range: NSRange(location: cursor, length: enclosing.location + enclosing.length - cursor),
            to: &result
        )
        try checkpoint()
        return result
    }

    mutating func append(_ source: NSString, range: NSRange, to result: inout String) throws {
        var cursor = range.location
        let end = range.location + range.length
        while cursor < end {
            let remaining = EditorReplaceLimits.cancellationUTF16Chunk - copiedSinceCheck
            var count = min(end - cursor, remaining)
            // A chunk may split a grapheme, but must preserve surrogate pairs.
            if !isScalarBoundary(cursor + count, in: source) {
                count -= 1
            }
            if count == 0 {
                try checkpoint()
                continue
            }
            result.append(source.substring(with: NSRange(location: cursor, length: count)))
            cursor += count
            let (copied, overflow) = copiedUTF16Count.addingReportingOverflow(count)
            guard !overflow else { throw invalid(.projectedLengthOverflow) }
            copiedUTF16Count = copied
            copiedSinceCheck += count
            if copiedSinceCheck == EditorReplaceLimits.cancellationUTF16Chunk {
                try checkpoint()
            }
        }
    }

    func reserveUTF16Capacity(_ length: Int, for result: inout String) throws {
        // At most three UTF-8 bytes per UTF-16 unit. One checked reservation
        // avoids a later append reallocating and recopying an unbounded prefix.
        let (capacity, overflow) = length.multipliedReportingOverflow(by: 3)
        guard length >= 0, !overflow else { throw invalid(.projectedLengthOverflow) }
        result.reserveCapacity(capacity)
    }

    func isScalarBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xD800 ... 0xDBFF).contains(source.character(at: offset - 1))
            || !(0xDC00 ... 0xDFFF).contains(source.character(at: offset))
    }

    func invalid(_ reason: EditorReplacePlanRefusal) -> EditorReplaceBatchPreparationFailure {
        .invalidPlan(reason)
    }
}
