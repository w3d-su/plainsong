/// Why a match was scheduled — decides whether completion emits navigation.
///
/// Product rules (docs/editor-find-gates.md §5.1):
/// - `.query` → navigate to the match resolved from the caret anchor
/// - `.edit` / `.rebind` → recompute session/counter only; do **not** move selection
enum EditorFindScheduleReason: Equatable {
    case query
    /// ⌘E / pattern-only: recompute counter, no auto-navigate.
    case patternOnly
    case edit
    case rebind
    /// One post-write rescan. `resumeUTF16` is the continuation anchor.
    case replacement(resumeUTF16: Int)

    var emitsNavigationOnCompletion: Bool {
        switch self {
        case .query, .replacement: true
        case .patternOnly, .edit, .rebind: false
        }
    }
}
