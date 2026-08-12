import Foundation

/// Fixed v1 bounds for in-document Replace (`docs/editor-replace-gates.md` §3.1, §5.3).
public enum EditorReplaceLimits {
    /// Maximum UTF-16 length of one replacement value.
    ///
    /// Matches the existing literal query scale. Combined with the 10,000-match
    /// ceiling this caps growth at `maximumGrowthUTF16`.
    public static let maximumReplacementUTF16Length = 256

    /// Maximum UTF-16 growth beyond the already-installed source for one batch.
    public static let maximumGrowthUTF16 = 2_560_000

    /// Cancellation/progress checkpoint: at most this many planned matches.
    public static let progressMatchChunk = 64

    /// Cancellation/progress checkpoint: at most this many copied UTF-16 units.
    public static let progressUTF16Chunk = 65536

    /// Maximum coalesced progress updates for one Replace All plan.
    public static let maximumProgressUpdates = 100
}
