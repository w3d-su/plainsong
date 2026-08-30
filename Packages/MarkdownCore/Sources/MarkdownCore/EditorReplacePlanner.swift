import Foundation

/// Pure Replace planner. Consumes `EditorFindSession` matches; does not search.
public enum EditorReplacePlanner {
    public static func planOneMatch(
        session: EditorFindSession,
        source: String,
        replacement: String
    ) -> Result<EditorReplaceOneMatchPlan, EditorReplacePlanRefusal> {
        switch EditorReplacePlanning.validateReplacement(replacement) {
        case .valid:
            break
        case let invalid:
            return .failure(.invalidReplacement(invalid))
        }
        guard session.total > 0 else {
            return .failure(.emptySession)
        }
        guard let match = session.currentMatch else {
            return .failure(.noCurrentMatch)
        }
        guard EditorReplacePlanning.slice(source, range: match.range) != nil else {
            return .failure(.noCurrentMatch)
        }
        let identical = EditorReplacePlanning.isLiteralIdentical(
            source: source,
            range: match.range,
            replacement: replacement
        )
        let replacementLength = (replacement as NSString).length
        let resume: Int
        if identical {
            guard let matchEnd = EditorReplacePlanning.rangeEnd(match.range) else {
                return .failure(.noCurrentMatch)
            }
            resume = matchEnd
        } else {
            let (value, overflow) = match.range.location.addingReportingOverflow(
                replacementLength
            )
            guard !overflow else {
                return .failure(.projectedLengthOverflow)
            }
            resume = value
            if EditorReplaceSourceConstruction.projectedUTF16Length(
                sourceLength: (source as NSString).length,
                ranges: [match.range],
                replacementUTF16Length: replacementLength
            ) == nil {
                return .failure(.projectedLengthOverflow)
            }
        }
        return .success(EditorReplaceOneMatchPlan(
            query: session.query,
            match: match,
            replacement: replacement,
            isLiteralIdentical: identical,
            resumeUTF16: resume
        ))
    }

    public static func planBatch(
        session: EditorFindSession,
        source: String,
        replacement: String
    ) -> Result<EditorReplaceBatchPlan, EditorReplacePlanRefusal> {
        switch EditorReplacePlanning.validateReplacement(replacement) {
        case .valid:
            break
        case let invalid:
            return .failure(.invalidReplacement(invalid))
        }
        guard !session.isTruncated else {
            return .failure(.truncatedSession)
        }
        guard session.total > 0 else {
            return .failure(.emptySession)
        }
        let replacementLength = (replacement as NSString).length
        var differing: [NSRange] = []
        differing.reserveCapacity(session.matches.count)
        var allRanges: [NSRange] = []
        allRanges.reserveCapacity(session.matches.count)
        for match in session.matches {
            allRanges.append(match.range)
            guard EditorReplacePlanning.slice(source, range: match.range) != nil else {
                return .failure(.noCurrentMatch)
            }
            if !EditorReplacePlanning.isLiteralIdentical(
                source: source,
                range: match.range,
                replacement: replacement
            ) {
                differing.append(match.range)
            }
        }
        guard let projected = EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: (source as NSString).length,
            ranges: differing,
            replacementUTF16Length: replacementLength
        ) else {
            return .failure(.projectedLengthOverflow)
        }
        return .success(EditorReplaceBatchPlan(
            query: session.query,
            replacement: replacement,
            allRanges: allRanges,
            differingRanges: differing,
            changedCount: differing.count,
            totalCount: session.total,
            enclosingRange: EditorReplaceSourceConstruction.enclosingRange(of: differing),
            projectedUTF16Length: projected
        ))
    }
}
