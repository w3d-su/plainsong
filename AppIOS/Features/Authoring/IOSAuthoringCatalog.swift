import Foundation

/// Shortcut metadata for lane 10. These values do not install `UIKeyCommand`s.
enum IOSAuthoringCatalog {
    static let installsKeyCommands = false
    static let formattingRefusal = "無法在這裡使用這個格式"
    static let compositionRefusal = "Finish the current composition first."
    static let editRefusal = "The document changed. Review the draft and try again."
    static let frontmatterRefusal = "This frontmatter field can't be written back."

    static let actions: [IOSAuthoringAction] = [
        action(.bold, "Bold", .toolbar, "b", .command),
        action(.italic, "Italic", .toolbar, "i", .command),
        action(.link, "Link", .toolbar, "k", .command),
        action(.heading(1), "Heading 1", .toolbarGroup("Heading"), "1", .command),
        action(.heading(2), "Heading 2", .toolbarGroup("Heading"), "2", .command),
        action(.heading(3), "Heading 3", .toolbarGroup("Heading"), "3", .command),
        action(.heading(4), "Heading 4", .toolbarGroup("Heading"), "4", .command),
        action(.heading(5), "Heading 5", .toolbarGroup("Heading"), "5", .command),
        action(.heading(6), "Heading 6", .toolbarGroup("Heading"), "6", .command),
        action(.code, "Code", .toolbarGroup("Code"), nil, []),
        action(.inlineCode, "Inline Code", .toolbarGroup("Code"), nil, []),
        action(.codeFence, "Code Fence", .toolbarGroup("Code"), "k", [.command, .shift]),
        action(.strikethrough, "Strikethrough", .formatMenu, "x", [.control, .command]),
        action(.paragraph, "Paragraph", .formatMenu, "0", .command),
        action(.quote, "Quote", .formatMenu, "q", [.command, .shift]),
        action(.inlineMath, "Insert Inline Math", .formatMenu, nil, []),
        action(.displayMath, "Insert Display Math", .formatMenu, nil, []),
        action(.checkbox, "Toggle Checkbox", .formatMenu, "l", .command),
        action(.formatTable, "Format Table", .formatMenu, "f", [.option, .command]),
        action(.find, "Find", .find, "f", .command),
        action(.nextMatch, "Find Next", .find, "g", .command),
        action(.previousMatch, "Find Previous", .find, "g", [.shift, .command]),
        action(.useSelectionForFind, "Use Selection for Find", .find, "e", .command),
        action(.singleReplace, "Replace", .find, nil, []),
    ]

    static func title(for id: IOSAuthoringActionID) -> String {
        actions.first { $0.id == id }?.title ?? "Edit"
    }

    static func keyboardIdentity(_ action: IOSAuthoringAction) -> String? {
        guard let keyboardInput = action.keyboardInput else { return nil }
        return "\(action.keyboardModifiers.rawValue):\(keyboardInput)"
    }

    private static func action(
        _ id: IOSAuthoringActionID,
        _ title: String,
        _ placement: IOSAuthoringActionPlacement,
        _ keyboardInput: String?,
        _ modifiers: IOSKeyboardModifiers
    ) -> IOSAuthoringAction {
        IOSAuthoringAction(
            id: id,
            title: title,
            accessibilityLabel: title,
            placement: placement,
            keyboardInput: keyboardInput,
            keyboardModifiers: modifiers
        )
    }
}
