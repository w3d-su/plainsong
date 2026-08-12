import Foundation

/// Whether a replacement field value may be used.
public enum EditorReplaceValueValidity: Equatable, Sendable {
    case valid
    case exceedsMaximumUTF16Length
    case containsNewline
}

/// Why a Replace / Replace All plan cannot be built.
public enum EditorReplacePlanRefusal: Equatable, Sendable, Error {
    case invalidReplacement(EditorReplaceValueValidity)
    case emptySession
    case noCurrentMatch
    case truncatedSession
    case projectedLengthOverflow
}

/// One current-match replacement. The session is the only match source.
public struct EditorReplaceOneMatchPlan: Equatable, Sendable {
    public let match: TextSearchMatch
    public let replacement: String
    public let isLiteralIdentical: Bool
    /// `match.range.location + replacement.utf16.count` after a real edit,
    /// or the old match end when the replacement is source-identical.
    public let resumeUTF16: Int
}

/// Exact-set Replace All plan over a non-truncated `EditorFindSession`.
public struct EditorReplaceBatchPlan: Equatable, Sendable {
    public let replacement: String
    public let allRanges: [NSRange]
    public let differingRanges: [NSRange]
    public let changedCount: Int
    public let totalCount: Int
    public let enclosingRange: NSRange?
    public let projectedUTF16Length: Int

    public var isNoOp: Bool {
        changedCount == 0
    }
}

/// Post-write Find continuation. `session.currentOrdinal` may be nil while
/// `session.matches` is non-empty.
public struct EditorReplaceContinuation: Equatable, Sendable {
    public let session: EditorFindSession
    public let resumeUTF16: Int
    public let collapsedSelection: NSRange
}

public enum EditorReplacePlanning {
    public static func validateReplacement(_ replacement: String) -> EditorReplaceValueValidity {
        if replacement.contains(where: \.isNewline) {
            return .containsNewline
        }
        if (replacement as NSString).length > EditorReplaceLimits.maximumReplacementUTF16Length {
            return .exceedsMaximumUTF16Length
        }
        return .valid
    }

    public static func slice(_ source: String, range: NSRange) -> String? {
        let nsSource = source as NSString
        guard range.location >= 0,
              NSMaxRange(range) <= nsSource.length
        else {
            return nil
        }
        return nsSource.substring(with: range)
    }

    public static func isLiteralIdentical(
        source: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        guard let slice = slice(source, range: range) else { return false }
        return ExactSourceText.matches(slice, replacement)
    }
}
