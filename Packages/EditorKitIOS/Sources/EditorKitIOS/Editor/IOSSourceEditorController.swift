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

    public convenience init(
        syntaxTokenizer: (any MarkdownSyntaxTokenizing)? = nil,
        theme: IOSEditorTheme = .light
    ) {
        self.init(
            syntaxTokenizer: syntaxTokenizer,
            theme: theme,
            debounce: IOSHighlightScheduler.productionDebounce
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
        applyThemeChrome()
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
        defer { isReconciling = false }
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
        raisePresentationFloor()
        scheduleHighlight()
    }
}
