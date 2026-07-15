import AppKit
import STTextView
import UniformTypeIdentifiers

@MainActor
final class MarkdownSTTextView: STTextView {
    var pasteHandler: ((MarkdownSTTextView, NSPasteboard) -> Bool)?
    var imageFileDropHandler: ((MarkdownSTTextView, [URL]) -> Bool)?
    var windowAttachmentHandler: ((MarkdownSTTextView) -> Void)?
    private(set) var isSuppressingIntermediateMarkedTextRemoval = false
    private var markedTextReplacementRange: NSRange?
    private var isMarkedTextReplacementRangeConfirmed = false
    var wysiwygZeroWidthContentStorageDelegate: WYSIWYGZeroWidthTextContentStorageDelegate?
    private var previousTextContentStorageDelegate: NSTextContentStorageDelegate?

    @discardableResult
    func setWYSIWYGZeroWidthFoldingEnabled(_ isEnabled: Bool) -> Bool {
        guard let textContentStorage = textContentManager as? NSTextContentStorage else {
            return false
        }

        if isEnabled {
            if let zeroWidthDelegate = wysiwygZeroWidthContentStorageDelegate,
               textContentStorage.delegate === zeroWidthDelegate
            {
                return true
            }

            let previousDelegate = textContentStorage.delegate
            let zeroWidthDelegate = WYSIWYGZeroWidthTextContentStorageDelegate(
                previousDelegate: previousDelegate
            )
            previousTextContentStorageDelegate = previousDelegate
            wysiwygZeroWidthContentStorageDelegate = zeroWidthDelegate
            textContentStorage.delegate = zeroWidthDelegate
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            return true
        } else {
            if textContentStorage.delegate === wysiwygZeroWidthContentStorageDelegate {
                textContentStorage.delegate = previousTextContentStorageDelegate
                textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            }
            wysiwygZeroWidthContentStorageDelegate?.previousDelegate = nil
            wysiwygZeroWidthContentStorageDelegate = nil
            previousTextContentStorageDelegate = nil
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.shouldReserveMarkedTextKeyForInputContext(event, hasMarkedText: hasMarkedText()) {
            let markedSnapshot = markedTextSnapshot()
            if let inputContext {
                _ = inputContext.handleEvent(event)
                restoreMarkedTextIfInputContextDiscarded(markedSnapshot, after: event)
            }
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        focusForMouseInteractionIfNeeded()

        guard wysiwygZeroWidthContentStorageDelegate != nil,
              let caret = wysiwygZeroWidthCharacterIndex(at: convert(event.locationInWindow, from: nil))
        else {
            super.mouseDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift) {
            // Pointer-extend (drag/shift-click) keeps raw offsets so the selection can
            // span folded delimiters and copy exact raw Markdown.
            let anchor = selectedRange().location
            textSelection = NSRange(location: min(anchor, caret), length: abs(caret - anchor))
        } else {
            // A plain click resolving to a hidden-delimiter offset snaps to the adjacent
            // visible boundary in the same pass as the reveal (no one-frame jump).
            let snappedCaret = wysiwygSnappedCaretOffset(caret, preferring: .nearest)
            textSelection = NSRange(location: snappedCaret, length: 0)
            revealWYSIWYGImagePresentationIfNeeded(at: caret)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            windowAttachmentHandler?(self)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange == .notFound, hasMarkedText() {
            let markedRange = markedRange()
            if markedRange.location != NSNotFound {
                let effectiveReplacementRange = markedTextReplacementRange ?? NSRange(
                    location: markedRange.location,
                    length: 0
                )
                isSuppressingIntermediateMarkedTextRemoval = true
                unmarkText()
                textSelection = effectiveReplacementRange
                isSuppressingIntermediateMarkedTextRemoval = false
                markedTextReplacementRange = nil
                isMarkedTextReplacementRangeConfirmed = false
                super.insertText(string, replacementRange: effectiveReplacementRange)
                ensureInsertionPointAfterInsertedText(
                    string,
                    at: effectiveReplacementRange.location
                )
                return
            }
        }

        if replacementRange == .notFound {
            ensureInsertionPointIfNeeded()
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    private func focusForMouseInteractionIfNeeded() {
        guard acceptsFirstResponder,
              window?.firstResponder !== self
        else {
            return
        }

        ensureInsertionPointIfNeeded()
        window?.makeFirstResponder(self)
    }

    private func ensureInsertionPointIfNeeded() {
        guard selectedRange().location == NSNotFound else {
            return
        }

        textSelection = NSRange(location: 0, length: 0)
    }

    private func ensureInsertionPointAfterInsertedText(_ string: Any, at insertionLocation: Int) {
        guard let insertedLength = Self.utf16Length(ofInsertedText: string) else {
            return
        }

        textSelection = NSRange(location: insertionLocation + insertedLength, length: 0)
    }

    private func markedTextSnapshot() -> MarkedTextSnapshot? {
        let range = markedRange()
        guard range.location != NSNotFound,
              let fullText = plainText(),
              let markedText = markedTextPlainString(in: range)
        else {
            return nil
        }

        return MarkedTextSnapshot(range: range, markedText: markedText, fullText: fullText)
    }

    private func restoreMarkedTextIfInputContextDiscarded(_ snapshot: MarkedTextSnapshot?, after event: NSEvent) {
        guard let snapshot,
              !hasMarkedText(),
              let currentText = plainText(),
              let replacementLength = discardedReplacementLength(
                  currentText: currentText,
                  snapshot: snapshot,
                  event: event
              )
        else {
            return
        }

        let replacementRange = NSRange(location: snapshot.range.location, length: replacementLength)
        textSelection = replacementRange
        guard !snapshot.markedText.isEmpty else {
            return
        }

        super.insertText(snapshot.markedText, replacementRange: replacementRange)
    }

    private func discardedReplacementLength(
        currentText: String,
        snapshot: MarkedTextSnapshot,
        event: NSEvent
    ) -> Int? {
        if let textAfterDeletingMarkedText = snapshot.fullText.replacing(range: snapshot.range, with: ""),
           textAfterDeletingMarkedText == currentText
        {
            return 0
        }

        for replacement in Self.strayReplacementStrings(forReservedMarkedTextKey: event) {
            if let textAfterStrayReplacement = snapshot.fullText.replacing(range: snapshot.range, with: replacement),
               textAfterStrayReplacement == currentText
            {
                return replacement.utf16.count
            }
        }

        return nil
    }

    private static func strayReplacementStrings(forReservedMarkedTextKey event: NSEvent) -> [String] {
        switch event.keyCode {
        case 36, 76:
            ["\n", "\r"]
        case 49:
            [" "]
        default:
            []
        }
    }

    private func markedTextPlainString(in range: NSRange) -> String? {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              range.location >= 0,
              NSMaxRange(range) <= textStorage.length
        else {
            return nil
        }

        return (textStorage.string as NSString).substring(with: range)
    }

    private func plainText() -> String? {
        (textContentManager as? NSTextContentStorage)?.textStorage?.string
    }

    private static func utf16Length(ofInsertedText string: Any) -> Int? {
        switch string {
        case let string as String:
            string.utf16.count
        case let attributedString as NSAttributedString:
            attributedString.length
        default:
            nil
        }
    }

    override func moveLeft(_ sender: Any?) {
        guard applyWYSIWYGComposedCharacterMovement(delta: -1, extending: false) else {
            super.moveLeft(sender)
            return
        }
    }

    override func moveRight(_ sender: Any?) {
        guard applyWYSIWYGComposedCharacterMovement(delta: 1, extending: false) else {
            super.moveRight(sender)
            return
        }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        guard applyWYSIWYGComposedCharacterMovement(delta: -1, extending: true) else {
            super.moveLeftAndModifySelection(sender)
            return
        }
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        guard applyWYSIWYGComposedCharacterMovement(delta: 1, extending: true) else {
            super.moveRightAndModifySelection(sender)
            return
        }
    }

    @objc override func paste(_ sender: Any?) {
        if pasteHandler?(self, .general) == true {
            return
        }

        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            return imageFileDropHandler == nil ? [] : .copy
        }

        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !Self.imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            guard imageFileDropHandler != nil else { return [] }
            _ = super.draggingUpdated(sender)
            return .copy
        }

        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let imageURLs = Self.imageFileURLs(from: sender.draggingPasteboard)
        guard !imageURLs.isEmpty else {
            return super.performDragOperation(sender)
        }

        _ = super.draggingUpdated(sender)
        return imageFileDropHandler?(self, imageURLs) == true
    }

    private func wysiwygZeroWidthCharacterIndex(at pointInView: CGPoint) -> Int? {
        let point = CGPoint(x: pointInView.x - (gutterView?.frame.width ?? 0), y: pointInView.y)
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        var nearest: (distance: CGFloat, offset: Int)?

        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let elementRange = NSRange(fragment.rangeInElement, in: textContentManager)
            for lineFragment in fragment.textLineFragments {
                let lineFrame = lineFragment.typographicBounds.offsetBy(
                    dx: fragment.layoutFragmentFrame.minX,
                    dy: fragment.layoutFragmentFrame.minY
                )
                let verticalDistance: CGFloat = if point.y < lineFrame.minY {
                    lineFrame.minY - point.y
                } else if point.y > lineFrame.maxY {
                    point.y - lineFrame.maxY
                } else {
                    0
                }

                guard nearest == nil || verticalDistance < nearest!.distance else {
                    continue
                }

                let localPoint = CGPoint(
                    x: point.x - lineFrame.minX,
                    y: point.y - lineFrame.minY
                )
                let localIndex = lineFragment.characterIndex(for: localPoint)
                let lineRange = NSRange(
                    location: elementRange.location + lineFragment.characterRange.location,
                    length: lineFragment.characterRange.length
                )
                let offset = min(max(lineRange.location + localIndex, lineRange.location), NSMaxRange(lineRange))
                nearest = (verticalDistance, offset)
            }
            return true
        }

        return nearest?.offset
    }

    private func applyWYSIWYGComposedCharacterMovement(delta: Int, extending: Bool) -> Bool {
        guard wysiwygZeroWidthContentStorageDelegate != nil,
              !hasMarkedText(),
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return false
        }

        let text = textStorage.string as NSString
        let textLength = text.length
        let selection = selectedRange().clamped(toLength: textLength)

        if extending {
            if delta < 0 {
                let location = text.composedCharacterBoundary(before: selection.location)
                textSelection = NSRange(location: location, length: NSMaxRange(selection) - location)
            } else {
                let end = text.composedCharacterBoundary(after: NSMaxRange(selection))
                textSelection = NSRange(location: selection.location, length: end - selection.location)
            }
        } else {
            let base = delta < 0 ? selection.location : NSMaxRange(selection)
            let movedLocation = delta < 0
                ? text.composedCharacterBoundary(before: base)
                : text.composedCharacterBoundary(after: base)
            // Edge-snapping: a collapsed caret never rests inside a folded (zero-width)
            // delimiter. Selections (the `extending` branch above) are left raw so copy
            // stays exact Markdown.
            let snappedLocation = wysiwygSnappedCaretOffset(
                movedLocation,
                preferring: delta < 0 ? .backward : .forward
            )
            textSelection = NSRange(location: snappedLocation, length: 0)
        }

        return true
    }
}

/// Caret edge-snapping for the non-user-facing WYSIWYG development hook.
///
/// When a *collapsed* caret would rest strictly inside a folded (zero-width) delimiter
/// run, it is relocated to that run's edge so it never visually sits on hidden
/// delimiters. Selection ranges are never clamped — only the caret rest position moves,
/// so a selection may still span raw delimiter offsets and copy stays exact raw Markdown.
enum WYSIWYGCaretSnap {
    enum Direction {
        /// Keyboard movement toward higher offsets — snap to the run's trailing edge.
        case forward
        /// Keyboard movement toward lower offsets — snap to the run's leading edge.
        case backward
        /// Pointer hit-test with no travel direction — snap to the nearer edge.
        case nearest
    }

    /// Returns `offset` unchanged unless it is strictly interior to one of
    /// `foldedDelimiterRanges`, in which case it snaps to that run's edge per `direction`.
    static func snap(offset: Int, foldedDelimiterRanges: [NSRange], preferring direction: Direction) -> Int {
        for range in foldedDelimiterRanges where offset > range.location && offset < NSMaxRange(range) {
            switch direction {
            case .forward:
                return NSMaxRange(range)
            case .backward:
                return range.location
            case .nearest:
                let distanceToLeading = offset - range.location
                let distanceToTrailing = NSMaxRange(range) - offset
                return distanceToLeading <= distanceToTrailing ? range.location : NSMaxRange(range)
            }
        }
        return offset
    }
}

private struct MarkedTextSnapshot {
    let range: NSRange
    let markedText: String
    let fullText: String
}

extension MarkdownSTTextView {
    func capturePotentialMarkedTextReplacementRange(_ range: NSRange) {
        guard markedTextReplacementRange == nil,
              range.location != NSNotFound
        else {
            return
        }
        markedTextReplacementRange = range
        isMarkedTextReplacementRangeConfirmed = false
    }

    func confirmPotentialMarkedTextReplacementRange(_ range: NSRange) {
        guard let candidate = markedTextReplacementRange,
              !isMarkedTextReplacementRangeConfirmed,
              range.location != NSNotFound
        else {
            return
        }

        // STTextView reports a zero-length native insertion when an initial
        // `.notFound` marked-text request begins over a selection. Preserve that
        // selected replacement span because it still exists after `unmarkText()`.
        // An explicit range is already removed while installing marked text, so its
        // final commit inserts at that range's lower boundary after the mark is
        // removed. An explicit zero-length range at another location does likewise.
        if range.length > 0 || range.location != candidate.location {
            markedTextReplacementRange = NSRange(location: range.location, length: 0)
        }
        isMarkedTextReplacementRangeConfirmed = true
    }

    func discardUnconfirmedMarkedTextReplacementRange() {
        guard !isMarkedTextReplacementRangeConfirmed else { return }
        markedTextReplacementRange = nil
    }

    func clearPotentialMarkedTextReplacementRangeIfUnmarked() {
        guard !hasMarkedText(),
              !isSuppressingIntermediateMarkedTextRemoval
        else {
            return
        }
        markedTextReplacementRange = nil
        isMarkedTextReplacementRangeConfirmed = false
    }

    static func shouldReserveMarkedTextKeyForInputContext(_ event: NSEvent, hasMarkedText: Bool) -> Bool {
        guard event.type == .keyDown,
              hasMarkedText,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else {
            return false
        }

        let imeSelectionKeys: Set<UInt16> = [36, 49, 76]
        return imeSelectionKeys.contains(event.keyCode)
    }

    static func imageAssets(from pasteboard: NSPasteboard) -> [EditorImageAsset] {
        let fileURLs = imageFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs.map(EditorImageAsset.file)
        }

        if let pngData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: pngPasteboardType) {
            return [.data(pngData, suggestedFilename: "image.png")]
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return []
        }

        return [.data(pngData, suggestedFilename: "image.png")]
    }

    static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []

        return objects
            .compactMap { object -> URL? in
                if let url = object as? URL {
                    return url
                }
                return (object as? NSURL)?.absoluteURL
            }
            .filter(isImageFileURL)
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension)
        else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static let pngPasteboardType = NSPasteboard.PasteboardType("public.png")
}

private extension NSString {
    func composedCharacterBoundary(before offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), length)
        guard clampedOffset > 0 else {
            return 0
        }

        return rangeOfComposedCharacterSequence(at: clampedOffset - 1).location
    }

    func composedCharacterBoundary(after offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), length)
        guard clampedOffset < length else {
            return length
        }

        return NSMaxRange(rangeOfComposedCharacterSequence(at: clampedOffset))
    }
}

private extension String {
    func replacing(range: NSRange, with replacement: String) -> String? {
        let nsString = self as NSString
        guard range.location >= 0,
              NSMaxRange(range) <= nsString.length
        else {
            return nil
        }

        return nsString.replacingCharacters(in: range, with: replacement)
    }
}
