import Foundation

/// Fixed v1 bounds for in-document Replace (`docs/editor-replace-gates.md` §3.1, §5.3).
public enum EditorReplaceLimits {
    /// Maximum UTF-16 length of one replacement value.
    ///
    /// Intentionally independent of TextSearchEngine.maximumPatternUTF16Length:
    /// §3.1 permits changing the replacement bound separately with owner evidence.
    /// The current defaults agree; the match ceiling derives the growth bound.
    public static let maximumReplacementUTF16Length = 256

    /// Maximum UTF-16 growth beyond the already-installed source for one batch.
    public static let maximumGrowthUTF16 =
        EditorFindLimits.retainedMatchCeiling * maximumReplacementUTF16Length

    /// Cancellation checkpoint: at most this many planned matches.
    public static let cancellationMatchChunk = 64

    /// Cancellation checkpoint: at most this many copied UTF-16 units.
    public static let cancellationUTF16Chunk = 65536

    /// Maximum coalesced progress updates for one Replace All plan.
    public static let maximumProgressUpdates = 100
}
