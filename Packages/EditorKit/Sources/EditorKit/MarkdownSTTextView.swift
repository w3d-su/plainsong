import AppKit
import STTextView
import UniformTypeIdentifiers

@MainActor
final class MarkdownSTTextView: STTextView {
    var pasteHandler: ((MarkdownSTTextView, NSPasteboard) -> Bool)?
    var imageFileDropHandler: ((MarkdownSTTextView, [URL]) -> Bool)?
    private var wysiwygZeroWidthContentStorageDelegate: WYSIWYGZeroWidthTextContentStorageDelegate?
    private var wysiwygPreviousTextContentStorageDelegate: NSTextContentStorageDelegate?

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
            wysiwygPreviousTextContentStorageDelegate = previousDelegate
            wysiwygZeroWidthContentStorageDelegate = zeroWidthDelegate
            textContentStorage.delegate = zeroWidthDelegate
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            return true
        } else {
            if textContentStorage.delegate === wysiwygZeroWidthContentStorageDelegate {
                textContentStorage.delegate = wysiwygPreviousTextContentStorageDelegate
                textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            }
            wysiwygZeroWidthContentStorageDelegate?.previousDelegate = nil
            wysiwygZeroWidthContentStorageDelegate = nil
            wysiwygPreviousTextContentStorageDelegate = nil
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.shouldReserveMarkedTextKeyForInputContext(event, hasMarkedText: hasMarkedText()),
           let inputContext
        {
            _ = inputContext.handleEvent(event)
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
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

    /// Snaps a collapsed-caret offset out of any folded delimiter interior, reading the
    /// live fold attributes so it reflects exactly what is currently hidden. Used by the
    /// non-user-facing WYSIWYG hook for keyboard arrow and pointer click rest positions.
    func wysiwygSnappedCaretOffset(_ offset: Int, preferring direction: WYSIWYGCaretSnap.Direction) -> Int {
        guard let foldedRange = wysiwygFoldedDelimiterRange(containingInterior: offset) else {
            return offset
        }

        return WYSIWYGCaretSnap.snap(
            offset: offset,
            foldedDelimiterRanges: [foldedRange],
            preferring: direction
        )
    }

    /// The folded delimiter run that strictly contains `offset` in its interior, or `nil`
    /// when `offset` sits at a run edge, in visible content, or folding is disabled.
    func wysiwygFoldedDelimiterRange(containingInterior offset: Int) -> NSRange? {
        guard wysiwygZeroWidthContentStorageDelegate != nil,
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              offset > 0,
              offset < textStorage.length
        else {
            return nil
        }

        // Bound the longest-effective-range scan to a small window. Folded delimiters are
        // short (heading markers and inline markers are at most a handful of characters),
        // so this stays O(1) on the caret-movement path while still spanning the whole run.
        let windowRadius = 16
        let lowerBound = max(0, offset - windowRadius)
        let upperBound = min(textStorage.length, offset + windowRadius)
        let searchRange = NSRange(location: lowerBound, length: upperBound - lowerBound)

        var effectiveRange = NSRange(location: 0, length: 0)
        let value = textStorage.attribute(
            WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
            at: offset - 1,
            longestEffectiveRange: &effectiveRange,
            in: searchRange
        )
        guard (value as? Bool) == true, offset < NSMaxRange(effectiveRange) else {
            return nil
        }
        return effectiveRange
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

extension MarkdownSTTextView {
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
