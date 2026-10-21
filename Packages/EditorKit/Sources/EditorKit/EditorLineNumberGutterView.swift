import AppKit
import STTextView

/// EditorKit's line-number gutter: a view beside the clip view that draws the numbers of
/// the laid-out fragments it can see.
///
/// STTextView 2.4.1's own gutter added ~10 ms to every layout pass in a 1 MiB document:
/// it rebuilt one `NSView` per visible line and counted every paragraph above the
/// viewport. This view only draws. A draw visits the layout fragments that intersect its
/// dirty rect, stops at the end of the TextKit viewport, and numbers each one with a
/// binary search in the shared line index. It never lays out or invalidates layout, so
/// IME marked text and scroll sync see no difference from line numbers.
///
/// `EditorScrollView` tiles it left of the clip view, so STTextView lays out text without a
/// gutter inset. (An `NSRulerView` floats over the clip view as a content inset, which
/// STTextView 2.4.1 does not subtract from its width.) The width only changes when the line
/// count needs another digit (or far fewer, with hysteresis), and never while text is being
/// composed.
@MainActor
final class EditorLineNumberGutterView: NSView {
    struct Style: Equatable {
        var font: NSFont
        var textColor: NSColor
        var currentLineTextColor: NSColor
    }

    nonisolated static let leadingInset: CGFloat = 4
    nonisolated static let trailingInset: CGFloat = 6
    /// Draws visit at most this many fragments, so a dirty rect TextKit has not laid out
    /// yet still costs a bounded amount.
    static let fragmentVisitLimit = 1000

    private weak var textView: MarkdownSTTextView?
    private var observers: [CoordinatorNotificationObserver] = []
    private(set) var style: Style
    private var digitWidth: CGFloat = 0
    private(set) var digits: Int?
    /// Width `EditorScrollView` gives the gutter.
    private(set) var thickness: CGFloat = 0
    private var needsThicknessUpdate = false
    /// Typeset numbers for the current style and appearance, keyed by `number * 2 + isCurrent`;
    /// scrolling and typing redraw mostly the same numbers.
    private var typesetNumbers: [Int: CTLine] = [:]
    private var typesetAppearance: NSAppearance.Name?
    private static let typesetNumberLimit = 1024

    /// Diagnostics for tests and probes.
    private(set) var lastDrawFragmentVisits = 0
    private(set) var drawCount = 0
    private(set) var lastDrawMilliseconds: Double = 0
    private(set) var totalDrawMilliseconds: Double = 0
    private(set) var thicknessChangeCount = 0
    private(set) var lastDrawnLabels: [EditorLineNumberGutterLayout.Label] = []

    init(textView: MarkdownSTTextView, scrollView: NSScrollView, style: Style) {
        self.textView = textView
        self.style = style
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        digitWidth = Self.digitWidth(of: style.font)
        updateThickness(tile: false)
        observe(textView, scrollView: scrollView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func update(style newStyle: Style) {
        guard newStyle != style else { return }
        let fontChanged = newStyle.font != style.font
        style = newStyle
        typesetNumbers.removeAll()
        if fontChanged {
            digitWidth = Self.digitWidth(of: newStyle.font)
            digits = nil
            updateThickness(tile: true)
        }
        needsDisplay = true
    }

    /// Removes observers; the owner removes the view from the scroll view.
    func detach() {
        observers.removeAll()
        textView?.lineIndexCache.textDidChangeHandler = nil
        textView = nil
    }

    /// TextKit laid out the viewport: fragment frames may have moved.
    func textViewDidLayoutViewport() {
        needsDisplay = true
    }

    // MARK: - Width

    private func textDidChange() {
        updateThickness(tile: true)
        needsDisplay = true
    }

    private func selectionDidChange() {
        if needsThicknessUpdate {
            updateThickness(tile: true)
        }
        needsDisplay = true
    }

    /// O(1) on the shared index while typing; a change of width retiles the scroll view,
    /// which re-wraps the text, so it waits for marked text to be committed.
    private func updateThickness(tile: Bool) {
        guard let textView else { return }
        guard !textView.hasMarkedText() else {
            needsThicknessUpdate = true
            return
        }
        needsThicknessUpdate = false
        let lineCount = textView.lineIndexCache.currentIndex().lineCount
        let nextDigits = EditorLineNumberGutterDigits.next(forLineCount: lineCount, current: digits)
        let newThickness = Self.thickness(digits: nextDigits, digitWidth: digitWidth)
        digits = nextDigits
        guard newThickness != thickness else { return }
        thickness = newThickness
        thicknessChangeCount += 1
        if tile {
            (superview as? NSScrollView)?.tile()
        }
    }

    nonisolated static func thickness(digits: Int, digitWidth: CGFloat) -> CGFloat {
        ceil(leadingInset + CGFloat(digits) * digitWidth + trailingInset)
    }

    private static func digitWidth(of font: NSFont) -> CGFloat {
        "0123456789".map { digit in
            (String(digit) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? font.pointSize
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            lastDrawMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            totalDrawMilliseconds += lastDrawMilliseconds
        }
        guard let textView else { return }

        if let backgroundColor = textView.backgroundColor {
            backgroundColor.setFill()
            dirtyRect.fill()
        }

        let top = convert(NSPoint(x: 0, y: dirtyRect.minY), to: textView).y
        let bottom = convert(NSPoint(x: 0, y: dirtyRect.maxY), to: textView).y
        let visible = EditorLineNumberGutterFragments.visible(
            in: textView,
            minY: min(top, bottom),
            maxY: max(top, bottom),
            limit: Self.fragmentVisitLimit
        )
        lastDrawFragmentVisits = visible.visited
        let selection = textView.selectedRange()
        let labels = EditorLineNumberGutterLayout.labels(
            for: visible.fragments,
            lineIndex: textView.lineIndexCache.currentIndex(),
            selection: selection
        )
        lastDrawnLabels = labels

        if textView.highlightSelectedLine, selection.length == 0 {
            drawCurrentLineBand(for: labels, in: textView)
        }
        drawNumbers(labels, in: textView)

        NSColor.separatorColor.withAlphaComponent(0.1).setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    /// STTextView highlights the caret's whole paragraph; the band matches it.
    private func drawCurrentLineBand(for labels: [EditorLineNumberGutterLayout.Label], in textView: STTextView) {
        textView.selectedLineHighlightColor.setFill()
        for label in labels where label.isCurrent {
            let minY = convert(NSPoint(x: 0, y: label.frame.minY), from: textView).y
            let maxY = convert(NSPoint(x: 0, y: label.frame.maxY), from: textView).y
            backingAlignedRect(
                NSRect(x: bounds.minX, y: min(minY, maxY), width: bounds.width, height: abs(maxY - minY)),
                options: .alignAllEdgesNearest
            ).fill()
        }
    }

    private func drawNumbers(_ labels: [EditorLineNumberGutterLayout.Label], in textView: STTextView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let appearance = effectiveAppearance.name
        if appearance != typesetAppearance || typesetNumbers.count > Self.typesetNumberLimit {
            typesetNumbers.removeAll()
            typesetAppearance = appearance
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for label in labels {
            let line = typesetNumber(label.number, isCurrent: label.isCurrent)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let baseline = convert(NSPoint(x: 0, y: label.baseline), from: textView).y
            context.textPosition = CGPoint(x: bounds.maxX - Self.trailingInset - width, y: baseline)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// Colors resolve for the appearance current while drawing.
    private func typesetNumber(_ number: Int, isCurrent: Bool) -> CTLine {
        let key = number * 2 + (isCurrent ? 1 : 0)
        if let line = typesetNumbers[key] {
            return line
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(number),
            attributes: [
                .font: style.font,
                .foregroundColor: (isCurrent ? style.currentLineTextColor : style.textColor).cgColor,
            ]
        ))
        typesetNumbers[key] = line
        return line
    }

    // MARK: - Observation

    private func observe(_ textView: MarkdownSTTextView, scrollView: NSScrollView) {
        let center = NotificationCenter.default
        observers.append(CoordinatorNotificationObserver(center.addObserver(
            forName: STTextView.didChangeSelectionNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionDidChange() }
        }))
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        observers.append(CoordinatorNotificationObserver(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }))
        textView.lineIndexCache.textDidChangeHandler = { [weak self] in
            self?.textDidChange()
        }
    }
}

extension EditorLineNumberGutterView.Style {
    /// The editor's gutter for these settings, or `nil` when line numbers are off.
    init?(showing showsLineNumbers: Bool, theme: MarkdownEditorTheme, font: NSFont) {
        guard showsLineNumbers else { return nil }
        let colors = MarkdownSyntaxTheme.builtIn(theme)
        self.init(font: font, textColor: colors.mutedColor, currentLineTextColor: colors.textColor)
    }
}
