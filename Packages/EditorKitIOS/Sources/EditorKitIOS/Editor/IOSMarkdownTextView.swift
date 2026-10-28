import UIKit

/// Source-mode editor surface. TextKit 2 only: no folds, attachments, or HTML editing.
public final class IOSMarkdownTextView: UITextView {
    weak var editor: IOSSourceEditorController?
    var viewportOverride: NSRange?
    var suppressesUndoRegistration = false
    let lineNumberGutter = IOSLineNumberGutterView()
    private(set) var baseTextContainerInset = UIEdgeInsets.zero
    private(set) var lineNumberGutterWidth: CGFloat = 0

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
        baseTextContainerInset = textContainerInset
        lineNumberGutter.isHidden = true
        addSubview(lineNumberGutter)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: IOSMarkdownTextView, _: UITraitCollection) in
            view.lineNumberGutter.setNeedsDisplay()
        }
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

    func applyLineNumberGutter(width: CGFloat, background: UIColor) {
        let nextWidth = max(0, width)
        let hidden = nextWidth <= 0
        let changed = abs(lineNumberGutterWidth - nextWidth) > 0.5 || lineNumberGutter.isHidden != hidden
        lineNumberGutterWidth = nextWidth
        lineNumberGutter.backgroundColor = background
        lineNumberGutter.isHidden = hidden
        if changed {
            let selected = selectedRange
            let offset = contentOffset
            var inset = textContainerInset
            inset.left = baseTextContainerInset.left + nextWidth
            textContainerInset = inset
            if selectedRange != selected {
                selectedRange = selected
            }
            if contentOffset != offset {
                contentOffset = offset
            }
            setNeedsLayout()
        }
        lineNumberGutter.setNeedsDisplay()
    }

    func setNeedsLineNumberDisplay() {
        lineNumberGutter.setNeedsDisplay()
    }

    /// Y in text-container coordinates for the source offset, laying out through that line.
    func contentY(forUTF16Offset offset: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let document = content.documentRange
        let length = content.offset(from: document.location, to: document.endLocation)
        guard length >= 0 else { return nil }
        let clamped = min(max(offset, 0), length)
        guard let location = content.location(document.location, offsetBy: clamped) else { return nil }
        if let through = NSTextRange(location: document.location, end: location) {
            manager.ensureLayout(for: through)
        }
        return manager.textLayoutFragment(for: location)?.layoutFragmentFrame.minY
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard lineNumberGutterWidth > 0 else { return }
        let frame = CGRect(
            x: contentOffset.x,
            y: contentOffset.y,
            width: lineNumberGutterWidth,
            height: bounds.height
        )
        if lineNumberGutter.frame != frame {
            lineNumberGutter.frame = frame
        }
        lineNumberGutter.setNeedsDisplay()
    }
}
