import UIKit

/// Source-mode editor surface. TextKit 2 only: no folds, attachments, or HTML editing.
public final class IOSMarkdownTextView: UITextView {
    weak var editor: IOSSourceEditorController?
    var viewportOverride: NSRange?
    var suppressesUndoRegistration = false

    override public var undoManager: UndoManager? {
        suppressesUndoRegistration ? nil : super.undoManager
    }

    /// `nil` container selects TextKit 2. Do not read `layoutManager`; that falls back to TextKit 1.
    public init() {
        super.init(frame: .zero, textContainer: nil)
        font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        backgroundColor = .systemBackground
        textColor = .label
        alwaysBounceVertical = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("IOSMarkdownTextView is created in code")
    }

    public var isTextKit2: Bool {
        textLayoutManager != nil
    }

    override public var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        let outdent = UIKeyCommand(
            input: "\t",
            modifierFlags: .shift,
            action: #selector(performOutdentFromKeyCommand)
        )
        outdent.wantsPriorityOverSystemBehavior = true
        commands.append(outdent)
        return commands
    }

    override public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        let marked = markedTextRange != nil || markedText?.isEmpty == false
        editor?.noteMarkedText(marked)
    }

    override public func unmarkText() {
        super.unmarkText()
        editor?.noteMarkedText(markedTextRange != nil)
    }

    override public func insertText(_ text: String) {
        if markedTextRange != nil {
            super.insertText(text)
            return
        }
        let range = selectedRange
        if editor?.consumeReplacement(text, range: range) == true {
            return
        }
        super.insertText(text)
    }

    @objc private func performOutdentFromKeyCommand() {
        editor?.performOutdent()
    }
}
