import Foundation

/// Stable accessibility identifiers for in-document find chrome (`plainsong.editorFind.*`).
enum EditorFindAccessibility {
    static let bar = "plainsong.editorFind.bar"
    static let queryField = "plainsong.editorFind.queryField"
    static let matchCase = "plainsong.editorFind.matchCase"
    static let wholeWord = "plainsong.editorFind.wholeWord"
    static let matchCounter = "plainsong.editorFind.matchCounter"
    static let truncatedIndicator = "plainsong.editorFind.truncated"
    static let nextButton = "plainsong.editorFind.next"
    static let previousButton = "plainsong.editorFind.previous"
    static let doneButton = "plainsong.editorFind.done"

    // Replacement row (Replace PR H, `docs/editor-replace-gates.md` §5.1).
    static let replaceDisclosure = "plainsong.editorFind.replaceDisclosure"
    static let replaceRow = "plainsong.editorFind.replaceRow"
    static let replacementField = "plainsong.editorFind.replacementField"
    static let replacementFieldError = "plainsong.editorFind.replacementFieldError"
    static let replaceButton = "plainsong.editorFind.replace"
    static let replaceAllButton = "plainsong.editorFind.replaceAll"
    static let replaceProgress = "plainsong.editorFind.replaceProgress"
    static let replaceCancelButton = "plainsong.editorFind.replaceCancel"
    static let replaceStatus = "plainsong.editorFind.replaceStatus"
    static let replaceBlockedReason = "plainsong.editorFind.replaceBlockedReason"
    static let replaceOverflow = "plainsong.editorFind.replaceOverflow"

    static let queryFieldLabel = "Editor find query"
    static let queryFieldPlaceholder = "Find"
    static let replacementFieldLabel = "Replacement text"
    static let replacementFieldPlaceholder = "Replace"
}
