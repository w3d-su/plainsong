import Foundation

/// Fixed v1 bounds for in-document find (docs/editor-find-gates.md §5.1).
///
/// The engine is **always** called with `engineMatchLimit` (`retainedMatchCeiling + 1`).
/// Truncation is detected by an overflow hit, not by an implementer-chosen second probe.
public enum EditorFindLimits {
    /// Maximum matches the session keeps; maximum exact counter `total`.
    public static let retainedMatchCeiling = 10000

    /// Argument always passed to `TextSearchEngine.matches` as `limit:`.
    public static let engineMatchLimit = retainedMatchCeiling + 1
}

/// Preference when resolving a 1-based ordinal from a caret anchor.
public enum EditorFindAnchorPreference: Sendable, Equatable {
    /// First match whose UTF-16 start is ≥ the anchor; wrap to the first match if none.
    case next
    /// Last match whose UTF-16 start is < the anchor; wrap to the last match if none.
    case previous
}

/// Pure in-document find session over `TextSearchEngine` results.
///
/// No I/O, no actors, no AppKit. Navigation IDs and off-main scheduling live in EditorKit.
public struct EditorFindSession: Equatable, Sendable {
    public let query: TextSearchQuery
    /// Retained matches only (≤ `EditorFindLimits.retainedMatchCeiling`).
    public let matches: [TextSearchMatch]
    public let isTruncated: Bool
    /// 1-based UI ordinal, or `nil` when there are no matches.
    public let currentOrdinal: Int?
    /// UTF-16 caret anchor used when resolving next/previous without an ordinal.
    public let caretAnchorUTF16: Int

    public var total: Int {
        matches.count
    }

    public var currentMatch: TextSearchMatch? {
        guard let currentOrdinal,
              matches.indices.contains(currentOrdinal - 1)
        else {
            return nil
        }
        return matches[currentOrdinal - 1]
    }

    /// Builds a session from raw engine results that were requested with
    /// `limit: EditorFindLimits.engineMatchLimit`.
    public init(
        engineResults: [TextSearchMatch],
        query: TextSearchQuery,
        caretAnchorUTF16: Int = 0,
        preferredOrdinal: Int? = nil
    ) {
        let ceiling = EditorFindLimits.retainedMatchCeiling
        let truncated = engineResults.count > ceiling
        let retained = truncated ? Array(engineResults.prefix(ceiling)) : engineResults
        self.init(
            retainedMatches: retained,
            isTruncated: truncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: preferredOrdinal
        )
    }

    /// Runs the engine with the fixed overflow limit and builds a session.
    public static func search(
        in text: String,
        query: TextSearchQuery,
        caretAnchorUTF16: Int = 0,
        preferredOrdinal: Int? = nil
    ) -> EditorFindSession {
        let engineResults = TextSearchEngine.matches(
            in: text,
            query: query,
            limit: EditorFindLimits.engineMatchLimit
        )
        return EditorFindSession(
            engineResults: engineResults,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: preferredOrdinal
        )
    }

    /// Empty / invalid query state (no matches, not truncated).
    public static func empty(
        query: TextSearchQuery,
        caretAnchorUTF16: Int = 0
    ) -> EditorFindSession {
        EditorFindSession(
            engineResults: [],
            query: query,
            caretAnchorUTF16: caretAnchorUTF16
        )
    }

    public func withCaretAnchor(_ caretAnchorUTF16: Int) -> EditorFindSession {
        EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: nil
        )
    }

    /// Matches remain, but there is no current hit (`0 / total` after Replace).
    ///
    /// Find search still resolves a nearest ordinal. Replace continuation must not
    /// wrap automatically when nothing starts at or after `resumeUTF16`.
    public func withUnresolvedCurrent(caretAnchorUTF16: Int) -> EditorFindSession {
        EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: nil,
            allowUnresolvedCurrent: true
        )
    }

    public func withCurrentOrdinal(
        _ ordinal: Int,
        caretAnchorUTF16: Int
    ) -> EditorFindSession {
        EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: ordinal
        )
    }

    public func next() -> EditorFindSession {
        guard !matches.isEmpty else { return self }
        let nextOrdinal: Int = if let currentOrdinal {
            currentOrdinal >= matches.count ? 1 : currentOrdinal + 1
        } else if let resolved = Self.ordinal(
            nearestTo: caretAnchorUTF16,
            preferring: .next,
            in: matches
        ) {
            resolved
        } else {
            1
        }
        return EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: nextOrdinal
        )
    }

    public func previous() -> EditorFindSession {
        guard !matches.isEmpty else { return self }
        let previousOrdinal: Int = if let currentOrdinal {
            currentOrdinal <= 1 ? matches.count : currentOrdinal - 1
        } else if let resolved = Self.ordinal(
            nearestTo: caretAnchorUTF16,
            preferring: .previous,
            in: matches
        ) {
            resolved
        } else {
            matches.count
        }
        return EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: previousOrdinal
        )
    }

    /// Applies `steps` wrapped next/previous steps in one operation.
    ///
    /// Positive steps behave like repeated `next()`, negative like repeated `previous()`,
    /// including the first-step caret-anchor resolution when `currentOrdinal` is `nil`.
    /// Repeated ⌘G / ⇧⌘G pressed while a generation is still computing must not be
    /// compressed into a single step, so the controller accumulates a net count and
    /// applies it here without an O(steps) loop.
    public func stepped(by steps: Int) -> EditorFindSession {
        guard !matches.isEmpty, steps != 0 else { return self }
        let total = matches.count
        // Reduce before any offset arithmetic so every `Int` magnitude (including
        // `Int.min`, which cannot be negated) stays in range.
        let wrapped = steps % total
        let startIndex: Int
        let offset: Int
        if let currentOrdinal {
            startIndex = currentOrdinal - 1
            offset = wrapped
        } else {
            let preference: EditorFindAnchorPreference = steps > 0 ? .next : .previous
            let resolved = Self.ordinal(
                nearestTo: caretAnchorUTF16,
                preferring: preference,
                in: matches
            ) ?? (steps > 0 ? 1 : total)
            // The anchor resolution *is* the first step, so only the rest are offsets.
            startIndex = resolved - 1
            offset = wrapped - (steps > 0 ? 1 : -1)
        }
        var index = (startIndex + offset) % total
        if index < 0 {
            index += total
        }
        return EditorFindSession(
            retainedMatches: matches,
            isTruncated: isTruncated,
            query: query,
            caretAnchorUTF16: caretAnchorUTF16,
            preferredOrdinal: index + 1
        )
    }

    /// 1-based ordinal nearest the caret for the given preference, or `nil` if empty.
    public static func ordinal(
        nearestTo anchor: Int,
        preferring preference: EditorFindAnchorPreference,
        in matches: [TextSearchMatch]
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        let safeAnchor = max(0, anchor)
        switch preference {
        case .next:
            if let index = matches.firstIndex(where: { $0.range.location >= safeAnchor }) {
                return index + 1
            }
            return 1
        case .previous:
            if let index = matches.lastIndex(where: { $0.range.location < safeAnchor }) {
                return index + 1
            }
            return matches.count
        }
    }

    private init(
        retainedMatches: [TextSearchMatch],
        isTruncated: Bool,
        query: TextSearchQuery,
        caretAnchorUTF16: Int,
        preferredOrdinal: Int?,
        allowUnresolvedCurrent: Bool = false
    ) {
        self.query = query
        matches = retainedMatches
        self.isTruncated = isTruncated
        self.caretAnchorUTF16 = max(0, caretAnchorUTF16)
        if retainedMatches.isEmpty {
            currentOrdinal = nil
        } else if allowUnresolvedCurrent, preferredOrdinal == nil {
            currentOrdinal = nil
        } else if let preferredOrdinal,
                  retainedMatches.indices.contains(preferredOrdinal - 1)
        {
            currentOrdinal = preferredOrdinal
        } else {
            currentOrdinal = Self.ordinal(
                nearestTo: self.caretAnchorUTF16,
                preferring: .next,
                in: retainedMatches
            )
        }
    }
}
