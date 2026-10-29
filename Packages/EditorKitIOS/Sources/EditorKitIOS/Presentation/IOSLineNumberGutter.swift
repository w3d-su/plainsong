import UIKit

struct IOSLineNumberLabel: Equatable {
    var number: Int
    /// Baseline in text-view content coordinates.
    var baseline: CGFloat
    var frame: CGRect
    var isCurrent: Bool
}

enum IOSLineNumberLayout {
    struct Fragment: Equatable {
        var location: Int
        var firstBaseline: CGFloat?
        var firstFrame: CGRect?
        var bodyFrame: CGRect?
        var extraBaseline: CGFloat?
        var extraFrame: CGRect?
    }

    /// Visible TextKit 2 fragments only. A label is one binary search in the line
    /// index, so drawing does not scan the document above the viewport.
    @MainActor
    static func labels(
        in textView: IOSMarkdownTextView,
        lineIndex: IOSSourceLineIndex,
        selection: NSRange
    ) -> [IOSLineNumberLabel] {
        let fragments = visibleFragments(in: textView)
        let current = currentLines(selection: selection, lineIndex: lineIndex)
        var labels: [IOSLineNumberLabel] = []
        labels.reserveCapacity(fragments.count)
        for fragment in fragments {
            if let baseline = fragment.firstBaseline,
               let frame = fragment.firstFrame ?? fragment.bodyFrame,
               let number = lineNumber(startingAt: fragment.location, in: lineIndex)
            {
                labels.append(IOSLineNumberLabel(
                    number: number,
                    baseline: baseline,
                    frame: fragment.bodyFrame ?? frame,
                    isCurrent: current?.contains(number) == true
                ))
            }
            if let baseline = fragment.extraBaseline, let frame = fragment.extraFrame,
               let number = lineNumber(startingAt: lineIndex.textUTF16Count, in: lineIndex)
            {
                labels.append(IOSLineNumberLabel(
                    number: number,
                    baseline: baseline,
                    frame: frame,
                    isCurrent: current?.contains(number) == true
                ))
            }
        }
        return labels
    }

    static func lineNumber(startingAt offset: Int, in lineIndex: IOSSourceLineIndex) -> Int? {
        guard offset >= 0, offset <= lineIndex.textUTF16Count else { return nil }
        let line = lineIndex.oneBasedLine(containingUTF16Offset: offset)
        return lineIndex.utf16Offset(forOneBasedLine: line) == offset ? line : nil
    }

    static func currentLines(selection: NSRange, lineIndex: IOSSourceLineIndex) -> ClosedRange<Int>? {
        guard selection.location != NSNotFound, selection.location >= 0 else { return nil }
        let first = lineIndex.oneBasedLine(containingUTF16Offset: selection.location)
        let last = selection.length > 0
            ? lineIndex.oneBasedLine(containingUTF16Offset: max(selection.location, NSMaxRange(selection) - 1))
            : first
        return first ... max(first, last)
    }

    static func width(lineCount: Int, font: UIFont, digits current: Int?) -> (width: CGFloat, digits: Int) {
        let digits = IOSLineNumberDigits.next(forLineCount: lineCount, current: current)
        let sample = String(repeating: "8", count: digits) as NSString
        let textWidth = ceil(sample.size(withAttributes: [.font: font]).width)
        return (textWidth + 18, digits)
    }

    @MainActor
    private static func visibleFragments(in textView: IOSMarkdownTextView) -> [Fragment] {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            return []
        }
        let document = content.documentRange
        if document.isEmpty {
            return emptyFragment(in: textView)
        }
        let viewport = layout.textViewportLayoutController.viewportRange
        let start = viewport?.location ?? document.location
        let minY = textView.contentOffset.y
        let maxY = minY + textView.bounds.height
        let inset = textView.textContainerInset
        var fragments: [Fragment] = []
        var visited = 0
        layout.enumerateTextLayoutFragments(from: start, options: [
            .ensuresLayout,
            .ensuresExtraLineFragment,
        ]) { fragment in
            visited += 1
            if visited > 400 { return false }
            if let viewport,
               fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending
            {
                return false
            }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: inset.left, dy: inset.top)
            if frame.minY > maxY + 2 { return false }
            guard frame.maxY >= minY - 2, fragment.state == .layoutAvailable else { return true }
            let location = content.offset(from: document.location, to: fragment.rangeInElement.location)
            guard location >= 0, location != NSNotFound else { return true }
            let end = content.offset(from: document.location, to: document.endLocation)
            fragments.append(makeFragment(fragment, location: location, origin: frame.origin, textEnd: end))
            return true
        }
        return fragments
    }

    /// UIKit's line fragment has no extra-line flag. The blank line after a
    /// trailing newline is the empty text line inside the last paragraph fragment.
    @MainActor
    private static func makeFragment(
        _ fragment: NSTextLayoutFragment,
        location: Int,
        origin: CGPoint,
        textEnd: Int
    ) -> Fragment {
        var result = Fragment(location: location)
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds
            let frame = bounds.offsetBy(dx: origin.x, dy: origin.y)
            let baseline = origin.y + bounds.minY + line.glyphOrigin.y
            // The extra blank line lives inside the last paragraph fragment, so the
            // fragment location is not the document end. Add the text-line offset.
            let lineStart = location + line.characterRange.location
            let isTrailingBlank = line.characterRange.length == 0 && lineStart == textEnd
            if isTrailingBlank {
                result.extraBaseline = baseline
                result.extraFrame = frame
            } else {
                if result.firstBaseline == nil {
                    result.firstBaseline = baseline
                    result.firstFrame = frame
                }
                result.bodyFrame = result.bodyFrame?.union(frame) ?? frame
            }
        }
        return result
    }

    @MainActor
    private static func emptyFragment(in textView: IOSMarkdownTextView) -> [Fragment] {
        let inset = textView.textContainerInset
        let font = textView.font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseline = inset.top + font.ascender
        let frame = CGRect(x: inset.left, y: inset.top, width: 1, height: max(font.lineHeight, 1))
        var fragment = Fragment(location: 0)
        fragment.firstBaseline = baseline
        fragment.firstFrame = frame
        fragment.bodyFrame = frame
        return [fragment]
    }
}

/// Pinned to the visible left edge. It does not take hits, so selection, scrolling,
/// and VoiceOver stay on the text.
final class IOSLineNumberGutterView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("IOSLineNumberGutterView is created in code")
    }

    override func draw(_ rect: CGRect) {
        guard let textView = superview as? IOSMarkdownTextView, let editor = textView.editor else { return }
        let labels = editor.currentLineNumberLabels()
        guard gutterWidth(of: textView) > 0 else { return }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        let separator = UIBezierPath()
        separator.move(to: CGPoint(x: bounds.width - hairline, y: 0))
        separator.addLine(to: CGPoint(x: bounds.width - hairline, y: bounds.height))
        editor.resolvedAppearanceColor(.separator).setStroke()
        separator.lineWidth = hairline
        separator.stroke()

        let font = editor.theme.baseFont
        let offsetY = textView.contentOffset.y
        for label in labels where rect.intersects(labelRect(label, offsetY: offsetY, width: bounds.width)) {
            let band = labelRect(label, offsetY: offsetY, width: bounds.width).insetBy(dx: 3, dy: 1)
            if label.isCurrent, band.height > 1 {
                editor.resolvedAppearanceColor(editor.theme.gutterBandColor).setFill()
                UIBezierPath(roundedRect: band, cornerRadius: 4).fill()
            }
            let text = "\(label.number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: editor.resolvedAppearanceColor(editor.theme.gutterColor(current: label.isCurrent)),
            ]
            let size = text.size(withAttributes: attributes)
            let origin = CGPoint(
                x: bounds.width - 8 - size.width,
                y: label.baseline - offsetY - font.ascender
            )
            text.draw(at: origin, withAttributes: attributes)
        }
    }

    private func gutterWidth(of textView: IOSMarkdownTextView) -> CGFloat {
        textView.lineNumberGutterWidth
    }

    private func labelRect(_ label: IOSLineNumberLabel, offsetY: CGFloat, width: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: label.frame.minY - offsetY,
            width: width,
            height: max(label.frame.height, 1)
        )
    }
}
