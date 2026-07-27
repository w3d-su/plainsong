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

    static let queryFieldLabel = "Editor find query"
    static let queryFieldPlaceholder = "Find"
}
