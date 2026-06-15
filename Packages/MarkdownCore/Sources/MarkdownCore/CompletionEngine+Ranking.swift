import Foundation

struct ScoredCompletion {
    let completion: Completion
    let score: Int
    let order: Int
}

extension CompletionEngine {
    func ranked(
        _ candidates: [RankedCompletion],
        query: String,
        workspace: CompletionWorkspace
    ) -> [Completion] {
        let normalizedQuery = normalized(query)
        let recentIDs = Set(workspace.recentlyUsedCompletionIDs)

        let scored = candidates.compactMap { candidate -> ScoredCompletion? in
            let score: Int
            if normalizedQuery.isEmpty {
                score = 1000
            } else {
                let matchText = normalized(candidate.matchText)
                if matchText.hasPrefix(normalizedQuery) {
                    score = 2000
                } else if fuzzyMatches(query: normalizedQuery, candidate: matchText) {
                    score = 1000
                } else {
                    return nil
                }
            }

            let recentBoost = recentIDs.contains(candidate.completion.id) ? 250 : 0
            return ScoredCompletion(
                completion: candidate.completion,
                score: score + recentBoost,
                order: candidate.order
            )
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.completion.label != rhs.completion.label {
                return lhs.completion.label.localizedStandardCompare(rhs.completion.label) == .orderedAscending
            }
            return lhs.order < rhs.order
        }
        .prefix(50)
        .map(\.completion)
    }

    func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    func normalized(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func fuzzyMatches(query: String, candidate: String) -> Bool {
        guard !query.isEmpty else { return true }

        var candidateIndex = candidate.startIndex
        for character in query {
            guard let match = candidate[candidateIndex...].firstIndex(of: character) else {
                return false
            }
            candidateIndex = candidate.index(after: match)
        }
        return true
    }
}
