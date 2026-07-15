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
