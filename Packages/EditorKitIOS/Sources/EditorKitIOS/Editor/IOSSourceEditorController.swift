import MarkdownCore
import SyntaxKit
import UIKit

/// Native UITextView writer. Authoring and image mutations enter only through `apply`.
@MainActor
public final class IOSSourceEditorController: NSObject, IOSSourceEditorBinding, UITextViewDelegate {
    public let textView: IOSMarkdownTextView
    public private(set) var isContentVisible = true
    public var theme: IOSEditorTheme {
        didSet { applyThemeChrome() }
    }

    /// Line numbers are presentation only. Source, selection, and statistics ignore them.
    public var showsLineNumbers = true {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            applyLineNumberChrome()
        }
    }

    /// Top visible source line after a real scroll. Typewriter sync listens; the editor does not.
    public var onViewportLine: ((Int) -> Void)?

    let scheduler: IOSHighlightScheduler
    let syntaxTokenizer: (any MarkdownSyntaxTokenizing)?
    var installation: IOSSourceEditorDocumentBinding?
    var observations: [IOSSourceEditorObservation] = []
    var selectionGeneration: UInt64 = 0
    var lastSelection = NSRange(location: 0, length: 0)
    var isCommandFocused = false
    var isMutating = false
    var isReconciling = false
    var isAdjustingSelection = false
    var isHostAlive = true
    var hadMarkedText = false
    var presentationGeneration: UInt64 = 0
    var presentationFloor: UInt64 = 0
    var lastSelectionViewport = NSRange(location: NSNotFound, length: 0)
    var beforeNativeMutation: (@MainActor (IOSSourceEditorController) -> Void)?
    var needsBaseStyle = false
    var lineIndex = IOSSourceLineIndex(text: "")
    var gutterDigits: Int?
    var lastViewportLine: Int?

    public convenience init(
        syntaxTokenizer: (any MarkdownSyntaxTokenizing)? = nil,
        theme: IOSEditorTheme = .light
    ) {
        self.init(
            syntaxTokenizer: syntaxTokenizer,
            theme: theme,
            debounce: { @Sendable in
                await IOSHighlightScheduler.productionDebounce()
            }
        )
    }

    init(
        syntaxTokenizer: (any MarkdownSyntaxTokenizing)?,
        theme: IOSEditorTheme,
        debounce: @escaping IOSHighlightScheduler.Debounce
    ) {
        textView = IOSMarkdownTextView()
        self.syntaxTokenizer = syntaxTokenizer
        self.theme = theme
        scheduler = IOSHighlightScheduler(debounce: debounce)
        super.init()
        textView.editor = self
        textView.delegate = self
        // Every storage edit (typing, marked text, autocorrect, undo, programmatic
        // replacement) updates the line index here, from the edit TextKit reports.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        applyThemeChrome()
        applyLineNumberChrome()
    }

    public var isTextKit2: Bool {
        textView.isTextKit2
    }

    public func captureSnapshot() -> IOSSourceEditorSnapshot? {
        guard isHostAlive, textView.isTextKit2, let installation else { return nil }
        return IOSSourceEditorSnapshot(
            bindingID: installation.bindingID,
            revision: currentRevision(installation),
            document: installation.session.snapshot,
            selection: textView.selectedRange,
            visibleRange: IOSViewport.visibleUTF16Range(in: textView),
            selectionGeneration: selectionGeneration,
            accessGeneration: installation.accessGeneration,
            hasMarkedText: textView.markedTextRange != nil,
            canWrite: installation.canWrite,
            isFocused: isCommandFocused
        )
    }

    public func attach(_ binding: IOSSourceEditorDocumentBinding) {
        guard isHostAlive, textView.isTextKit2 else { return }
        if let installation {
            emit(.detached(documentID: installation.identity, bindingID: installation.bindingID))
        }
        fenceInstallation()
        installation = binding
        isCommandFocused = false
        installInitialText(binding.session.text)
        selectionGeneration = 1
        lastSelection = textView.selectedRange
        emitSnapshot()
        scheduleHighlight()
    }

    public func detach(expected identity: IOSDocumentIdentity, bindingID: UUID) {
        guard let installation,
              installation.identity == identity,
              installation.bindingID == bindingID
        else {
            return
        }
        fenceInstallation()
        self.installation = nil
        isCommandFocused = false
        emit(.detached(documentID: identity, bindingID: bindingID))
    }

    public func updateAccess(
        for identity: IOSDocumentIdentity,
        bindingID: UUID,
        generation: UInt64,
        canWrite: Bool
    ) {
        guard var installation,
              installation.identity == identity,
              installation.bindingID == bindingID
        else {
            return
        }
        installation = IOSSourceEditorDocumentBinding(
            bindingID: installation.bindingID,
            identity: installation.identity,
            session: installation.session,
            accessGeneration: generation,
            canWrite: canWrite
        )
        self.installation = installation
        emitSnapshot()
    }

    public func updateCommandFocus(
        for identity: IOSDocumentIdentity,
        bindingID: UUID,
        isFocused: Bool
    ) {
        guard let installation,
              installation.identity == identity,
              installation.bindingID == bindingID
        else {
            return
        }
        guard isCommandFocused != isFocused else { return }
        isCommandFocused = isFocused
        emitSnapshot()
    }

    public func observe(
        _ handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void
    ) -> any IOSObservation {
        let observation = IOSSourceEditorObservation(handler: handler)
        observations.append(observation)
        return observation
    }

    public func setContentVisible(_ visible: Bool) {
        guard visible != isContentVisible else { return }
        isContentVisible = visible
        textView.isHidden = !visible
        if visible {
            scheduler.activate()
            scheduleHighlight()
        } else {
            scheduler.cancel()
        }
    }

    /// SwiftUI `updateUIView` must not push text back into the native view.
    public func acceptInterfaceUpdate() {}

    func invalidateHost() {
        isHostAlive = false
        scheduler.cancel()
        presentationGeneration &+= 1
        presentationFloor = presentationGeneration
        observations.forEach { $0.cancel() }
        observations.removeAll()
    }

    func plainText() -> String {
        textView.textStorage.string
    }

    func noteViewportChanged() {
        scheduleHighlight()
    }

    private func fenceInstallation() {
        scheduler.cancel()
        scheduler.activate()
        presentationGeneration &+= 1
        presentationFloor = presentationGeneration
        textView.undoManager?.removeAllActions()
        hadMarkedText = false
    }

    private func installInitialText(_ text: String) {
        isReconciling = true
        defer {
            isReconciling = false
            rebuildLineIndex()
        }
        guard !ExactSourceFragment.matches(plainText(), text) else { return }
        _ = IOSNativeTextMutation.replaceBufferWithoutUndo(text, in: textView)
        textView.selectedRange = NSRange(location: 0, length: 0)
    }

    func currentRevision(_ installation: IOSSourceEditorDocumentBinding) -> IOSDocumentRevision {
        IOSDocumentRevision(documentID: installation.identity, version: installation.session.version)
    }

    func emitSnapshot() {
        guard let snapshot = captureSnapshot() else { return }
        emit(.snapshotChanged(snapshot))
    }

    func emit(_ event: IOSSourceEditorEvent) {
        observations.forEach { $0.emit(event) }
    }

    private func applyThemeChrome() {
        textView.backgroundColor = theme.background
        applyLineNumberChrome()
        if textView.markedTextRange != nil {
            needsBaseStyle = true
            raisePresentationFloor()
            return
        }
        applyBaseTextStyle()
        raisePresentationFloor()
        scheduleHighlight()
    }

    /// Plain paragraphs and new typing use the theme. Syntax paint runs after
    /// this and only restyles token ranges. Source, undo, and marked text stay.
    func applyBaseTextStyle() {
        needsBaseStyle = false
        isReconciling = true
        textView.suppressesUndoRegistration = true
        let selectedRange = textView.selectedRange
        let contentOffset = textView.contentOffset
        defer {
            if textView.selectedRange != selectedRange {
                textView.selectedRange = selectedRange
            }
            if textView.contentOffset != contentOffset {
                textView.contentOffset = contentOffset
            }
            textView.suppressesUndoRegistration = false
            isReconciling = false
        }
        let storage = textView.textStorage
        let full = NSRange(location: 0, length: storage.length)
        if full.length > 0 {
            var plainRanges: [NSRange] = []
            storage.enumerateAttribute(IOSSyntaxAttribute.key, in: full) { value, range, _ in
                guard value == nil else { return }
                plainRanges.append(range)
            }
            storage.beginEditing()
            for range in plainRanges {
                storage.addAttributes(
                    [
                        .font: theme.baseFont,
                        .foregroundColor: theme.baseColor,
                    ],
                    range: range
                )
            }
            storage.endEditing()
        }
        textView.font = theme.baseFont
        textView.textColor = theme.baseColor
        var typing = textView.typingAttributes
        typing[.font] = theme.baseFont
        typing[.foregroundColor] = theme.baseColor
        textView.typingAttributes = typing
    }

    func currentLineNumberLabels() -> [IOSLineNumberLabel] {
        guard showsLineNumbers else { return [] }
        return IOSLineNumberLayout.labels(in: textView, lineIndex: lineIndex, selection: textView.selectedRange)
    }

    /// Lays out before reading, for tests and for the gutter's first paint.
    func lineNumberLabels() -> [IOSLineNumberLabel] {
        textView.layoutIfNeeded()
        return currentLineNumberLabels()
    }

    public func topVisibleSourceLine() -> Int {
        let range = IOSViewport.visibleUTF16Range(in: textView)
        let location = range.location == NSNotFound ? 0 : range.location
        return lineIndex.oneBasedLine(containingUTF16Offset: location)
    }

    /// Scrolls the source line to the top of the viewport. Used by typewriter sync.
    public func scrollToSourceLine(_ line: Int) {
        guard isHostAlive, textView.isTextKit2 else { return }
        let clamped = min(max(line, 1), max(lineIndex.lineCount, 1))
        let offset = lineIndex.utf16Offset(forOneBasedLine: clamped)
        guard let fragmentY = textView.contentY(forUTF16Offset: offset) else { return }
        // Fragment frames are in text-container coordinates; the content offset that puts
        // the line at the top of the visible area adds the container inset and starts at
        // the negative top inset (under the navigation bar), like the gutter.
        let target = Self.scrollTarget(
            fragmentY: fragmentY,
            containerInsetTop: textView.textContainerInset.top,
            adjustedInset: textView.adjustedContentInset,
            contentHeight: textView.contentSize.height,
            boundsHeight: textView.bounds.height
        )
        guard abs(textView.contentOffset.y - target) > 0.5 else { return }
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: target), animated: false)
    }

    nonisolated static func scrollTarget(
        fragmentY: CGFloat,
        containerInsetTop: CGFloat,
        adjustedInset: UIEdgeInsets,
        contentHeight: CGFloat,
        boundsHeight: CGFloat
    ) -> CGFloat {
        let minimum = -adjustedInset.top
        let maximum = max(minimum, contentHeight - boundsHeight + adjustedInset.bottom)
        // The first line scrolls to the very top, keeping the container inset above it.
        guard fragmentY > 0 else { return minimum }
        return min(max(minimum, fragmentY + containerInsetTop - adjustedInset.top), maximum)
    }

    func noteViewportLine() {
        let line = topVisibleSourceLine()
        guard line != lastViewportLine else { return }
        lastViewportLine = line
        onViewportLine?(line)
    }

    /// Applies the storage's processed edit to the line index. `editedRange` is in post-edit
    /// coordinates and covers every change in the batch, so the pre-edit range is the same
    /// location with `changeInLength` removed. A failed or mismatched update rebuilds.
    @objc func textStorageDidProcessEditing(_ notification: Notification) {
        let storage = textView.textStorage
        guard notification.object as AnyObject === storage,
              storage.editedMask.contains(.editedCharacters)
        else { return }
        let edited = storage.editedRange
        let previousLength = edited.length - storage.changeInLength
        let source = storage.string as NSString
        guard edited.location != NSNotFound, previousLength >= 0, NSMaxRange(edited) <= source.length else {
            lineIndex = IOSSourceLineIndex(utf16: source)
            return
        }
        let applied = lineIndex.replaceCharacters(
            in: NSRange(location: edited.location, length: previousLength),
            with: source.substring(with: edited)
        )
        if !applied || lineIndex.textUTF16Count != source.length {
            lineIndex = IOSSourceLineIndex(utf16: source)
        }
    }

    func rebuildLineIndex() {
        lineIndex = IOSSourceLineIndex(text: plainText())
        applyLineNumberChrome()
    }

    func applyLineNumberChrome() {
        let metrics = showsLineNumbers
            ? IOSLineNumberLayout.width(lineCount: lineIndex.lineCount, font: theme.baseFont, digits: gutterDigits)
            : (width: CGFloat(0), digits: gutterDigits ?? IOSLineNumberDigits.minimum)
        if showsLineNumbers {
            gutterDigits = metrics.digits
        }
        isAdjustingSelection = true
        defer { isAdjustingSelection = false }
        textView.applyLineNumberGutter(width: metrics.width, background: theme.background)
    }
}
