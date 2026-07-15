/// Three-way reconciliation for editor publications that were based on an older model
/// revision. Work is performed on literal UTF-16 code units so source identity is never
/// normalized. The normal typing path does not call this helper; it is reserved for a
/// stale publication after another accepted mutation advanced the session.
public extension ExactSourceText {
    static func reconciling(
        base: String,
        current: String,
        proposed: String
    ) -> String? {
        if matches(current, base) {
            return proposed
        }
        if matches(proposed, base) || matches(current, proposed) {
            return current
        }

        let baseUnits = Array(base.utf16)
        let currentUnits = Array(current.utf16)
        let proposedUnits = Array(proposed.utf16)
        guard let currentEdits = sourceEdits(from: baseUnits, to: currentUnits),
              let proposedEdits = sourceEdits(from: baseUnits, to: proposedUnits)
        else {
            return nil
        }

        var mergedEdits = currentEdits
        for proposedEdit in proposedEdits {
            if mergedEdits.contains(proposedEdit) {
                continue
            }
            guard !mergedEdits.contains(where: { editsConflict($0, proposedEdit) }) else {
                return nil
            }
            mergedEdits.append(proposedEdit)
        }

        var mergedUnits = baseUnits
        for edit in mergedEdits.sorted(by: descendingSourceOrder) {
            mergedUnits.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(decoding: mergedUnits, as: UTF16.self)
    }
}

private extension ExactSourceText {
    struct SourceEdit: Equatable {
        let range: Range<Int>
        let replacement: [UInt16]
    }

    static func sourceEdits(
        from base: [UInt16],
        to target: [UInt16]
    ) -> [SourceEdit]? {
        guard let edits = alignedSourceEdits(from: base, to: target) else {
            return nil
        }
        let editDistance = edits.reduce(into: 0) { distance, edit in
            distance += edit.range.count + edit.replacement.count
        }

        // CollectionDifference returns one optimal alignment, but repeated source
        // units can admit another equally short alignment at a different offset.
        // Offset is merge provenance: if it is not unique, fail closed instead of
        // silently applying a stale edit at an arbitrary occurrence.
        guard hasUniqueOptimalAlignment(
            from: base,
            to: target,
            editDistance: editDistance
        )
        else {
            return nil
        }
        return edits
    }

    static func alignedSourceEdits(
        from base: [UInt16],
        to target: [UInt16]
    ) -> [SourceEdit]? {
        var commonPrefixCount = 0
        while commonPrefixCount < base.count,
              commonPrefixCount < target.count,
              base[commonPrefixCount] == target[commonPrefixCount]
        {
            commonPrefixCount += 1
        }
        var commonSuffixCount = 0
        while commonSuffixCount < base.count - commonPrefixCount,
              commonSuffixCount < target.count - commonPrefixCount,
              base[base.count - commonSuffixCount - 1] == target[target.count - commonSuffixCount - 1]
        {
            commonSuffixCount += 1
        }

        let baseMiddle = Array(base[
            commonPrefixCount ..< (base.count - commonSuffixCount)
        ])
        let targetMiddle = Array(target[
            commonPrefixCount ..< (target.count - commonSuffixCount)
        ])
        let difference = targetMiddle.difference(from: baseMiddle)
        var removedOffsets: Set<Int> = []
        var insertedOffsets: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var edits: [SourceEdit] = []
        var baseOffset = 0
        var targetOffset = 0
        var editStart: Int?
        var replacement: [UInt16] = []

        func finishEdit() {
            guard let editStart else { return }
            edits.append(SourceEdit(
                range: (commonPrefixCount + editStart) ..< (commonPrefixCount + baseOffset),
                replacement: replacement
            ))
        }

        while baseOffset < baseMiddle.count || targetOffset < targetMiddle.count {
            let removesBase = baseOffset < baseMiddle.count && removedOffsets.contains(baseOffset)
            let insertsTarget = targetOffset < targetMiddle.count && insertedOffsets.contains(targetOffset)
            if removesBase || insertsTarget {
                if editStart == nil {
                    editStart = baseOffset
                }
                if removesBase {
                    baseOffset += 1
                }
                if insertsTarget {
                    replacement.append(targetMiddle[targetOffset])
                    targetOffset += 1
                }
                continue
            }

            guard baseOffset < baseMiddle.count,
                  targetOffset < targetMiddle.count,
                  baseMiddle[baseOffset] == targetMiddle[targetOffset]
            else {
                return nil
            }
            finishEdit()
            editStart = nil
            replacement.removeAll(keepingCapacity: true)
            baseOffset += 1
            targetOffset += 1
        }
        finishEdit()
        return edits
    }

    struct AlignmentNode: Hashable {
        let previousID: Int
        let baseOffset: Int
        let targetOffset: Int
    }

    struct AlignmentState {
        static let invalid = AlignmentState(length: -1, firstID: 0, secondID: nil)

        var length: Int
        var firstID: Int
        var secondID: Int?

        var isValid: Bool {
            length >= 0
        }

        mutating func formUnion(with other: AlignmentState) {
            guard other.isValid else { return }
            if !isValid || other.length > length {
                self = other
                return
            }
            guard other.length == length else { return }
            insert(other.firstID)
            if let secondID = other.secondID {
                insert(secondID)
            }
        }

        private mutating func insert(_ identifier: Int) {
            guard identifier != firstID, identifier != secondID else { return }
            if secondID == nil {
                secondID = identifier
            }
        }
    }

    /// Proves that the maximum-LCS alignment has exactly one sequence of matched
    /// source/target offsets. Different insertion/deletion interleavings that retain
    /// the same matches coalesce to one identifier because they produce the same
    /// source edits; different matched offsets remain distinct provenance.
    static func hasUniqueOptimalAlignment(
        from base: [UInt16],
        to target: [UInt16],
        editDistance: Int
    ) -> Bool {
        if editDistance == 0 {
            return true
        }

        var commonPrefixCount = 0
        while commonPrefixCount < base.count,
              commonPrefixCount < target.count,
              base[commonPrefixCount] == target[commonPrefixCount]
        {
            commonPrefixCount += 1
        }
        var commonSuffixCount = 0
        while commonSuffixCount < base.count - commonPrefixCount,
              commonSuffixCount < target.count - commonPrefixCount,
              base[base.count - commonSuffixCount - 1] == target[target.count - commonSuffixCount - 1]
        {
            commonSuffixCount += 1
        }

        // Keep an edit-distance-sized boundary around the changed middle. Any
        // alternate optimal alignment can drift by at most its insertion/deletion
        // distance, so this retains enough equal context to expose repeated-unit ties
        // without constructing an O(n*m) table for an otherwise unchanged document.
        let baseStart = max(0, commonPrefixCount - editDistance)
        let targetStart = baseStart
        let baseEnd = min(base.count, base.count - commonSuffixCount + editDistance)
        let targetEnd = min(target.count, target.count - commonSuffixCount + editDistance)
        let baseCount = baseEnd - baseStart
        let targetCount = targetEnd - targetStart

        // Reconciliation is a stale-publication recovery path. Refuse unusually
        // expensive ambiguity proofs rather than risking an unbounded quadratic merge.
        let bandWidth = min(targetCount + 1, editDistance * 2 + 1)
        let (work, overflow) = (baseCount + 1).multipliedReportingOverflow(by: bandWidth)
        guard !overflow, work <= 4_000_000 else {
            return false
        }

        let emptyAlignment = AlignmentState(length: 0, firstID: 0, secondID: nil)
        var previous: [Int: AlignmentState] = [:]
        for targetOffset in 0 ... min(targetCount, editDistance) {
            previous[targetOffset] = emptyAlignment
        }

        var nodeIDs: [AlignmentNode: Int] = [:]
        var nextNodeID = 1

        func appendingMatch(
            to state: AlignmentState,
            baseOffset: Int,
            targetOffset: Int
        ) -> AlignmentState {
            guard state.isValid else { return .invalid }

            func identifier(after previousID: Int) -> Int {
                let node = AlignmentNode(
                    previousID: previousID,
                    baseOffset: baseStart + baseOffset,
                    targetOffset: targetStart + targetOffset
                )
                if let identifier = nodeIDs[node] {
                    return identifier
                }
                let identifier = nextNodeID
                nextNodeID += 1
                nodeIDs[node] = identifier
                return identifier
            }

            return AlignmentState(
                length: state.length + 1,
                firstID: identifier(after: state.firstID),
                secondID: state.secondID.map(identifier(after:))
            )
        }

        if baseCount > 0 {
            for baseOffset in 1 ... baseCount {
                let minimumTargetOffset = max(0, baseOffset - editDistance)
                let maximumTargetOffset = min(targetCount, baseOffset + editDistance)
                var current: [Int: AlignmentState] = [:]

                for targetOffset in minimumTargetOffset ... maximumTargetOffset {
                    var best = AlignmentState.invalid
                    if let skippedBase = previous[targetOffset] {
                        best.formUnion(with: skippedBase)
                    }
                    if let skippedTarget = current[targetOffset - 1] {
                        best.formUnion(with: skippedTarget)
                    }
                    if targetOffset > 0,
                       base[baseStart + baseOffset - 1] == target[targetStart + targetOffset - 1],
                       let diagonal = previous[targetOffset - 1]
                    {
                        best.formUnion(with: appendingMatch(
                            to: diagonal,
                            baseOffset: baseOffset - 1,
                            targetOffset: targetOffset - 1
                        ))
                    }
                    if best.isValid {
                        current[targetOffset] = best
                    }
                }
                previous = current
            }
        }

        guard let result = previous[targetCount] else {
            return false
        }
        let provenEditDistance = baseCount + targetCount - result.length * 2
        return provenEditDistance == editDistance && result.secondID == nil
    }

    static func editsConflict(_ lhs: SourceEdit, _ rhs: SourceEdit) -> Bool {
        if lhs.range.isEmpty, rhs.range.isEmpty {
            return lhs.range.lowerBound == rhs.range.lowerBound
        }
        if lhs.range.isEmpty {
            return rhs.range.lowerBound < lhs.range.lowerBound &&
                lhs.range.lowerBound < rhs.range.upperBound
        }
        if rhs.range.isEmpty {
            return lhs.range.lowerBound < rhs.range.lowerBound &&
                rhs.range.lowerBound < lhs.range.upperBound
        }
        return lhs.range.overlaps(rhs.range)
    }

    static func descendingSourceOrder(_ lhs: SourceEdit, _ rhs: SourceEdit) -> Bool {
        if lhs.range.lowerBound == rhs.range.lowerBound {
            return lhs.range.upperBound > rhs.range.upperBound
        }
        return lhs.range.lowerBound > rhs.range.lowerBound
    }
}
