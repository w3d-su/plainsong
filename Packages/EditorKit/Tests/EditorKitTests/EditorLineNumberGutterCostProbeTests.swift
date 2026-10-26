import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Opt-in (PLAINSONG_RUN_GUTTER_PROBE=1) cost of line numbers on `Fixtures/large-1mb.md`,
/// line numbers off and on interleaved in one process. Run release-optimized:
/// `PLAINSONG_RUN_GUTTER_PROBE=1 swift test -c release -Xswiftc -enable-testing
/// --filter EditorLineNumberGutterCostProbeTests`. Loaded-machine timings are diagnostics.
@MainActor
final class EditorLineNumberGutterCostProbeTests: XCTestCase {
    private struct Samples {
        var insert: [Double] = []
        var layout: [Double] = []
        var display: [Double] = []
        var keystroke: [Double] = []
        var scrollLayout: [Double] = []
        var scrollDisplay: [Double] = []
        /// Synchronous full draws of the gutter (EditorKit gutter only).
        var gutterDraw: [Double] = []
        var gutterDrawsDuringTyping: [Double] = []
        var scrollGutterDraw: [Double] = []

        mutating func append(_ other: Self) {
            insert += other.insert
            layout += other.layout
            display += other.display
            keystroke += other.keystroke
            scrollLayout += other.scrollLayout
            scrollDisplay += other.scrollDisplay
            gutterDraw += other.gutterDraw
            gutterDrawsDuringTyping += other.gutterDrawsDuringTyping
            scrollGutterDraw += other.scrollGutterDraw
        }
    }

    func testLineNumberCostOnLargeFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLAINSONG_RUN_GUTTER_PROBE"] == "1" else {
            throw XCTSkip("Line-number cost probe is opt-in: PLAINSONG_RUN_GUTTER_PROBE=1")
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-1mb.md")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let rounds = Int(environment["PLAINSONG_GUTTER_PROBE_ROUNDS"] ?? "") ?? 3
        let position = Double(environment["PLAINSONG_GUTTER_PROBE_POSITION"] ?? "") ?? 0.5
        var off = Samples()
        var on = Samples()
        for round in 0 ..< rounds {
            for lineNumbers in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                let samples = try measure(source, lineNumbers: lineNumbers, position: position)
                if lineNumbers { on.append(samples) } else { off.append(samples) }
            }
        }
        var report: [String: Any] = [:]
        for (name, samples) in [("off", off), ("on", on)] {
            report[name] = [
                "insertMedian": Self.median(samples.insert),
                "layoutMedian": Self.median(samples.layout),
                "layoutP95": Self.percentile(samples.layout, 0.95),
                "displayMedian": Self.median(samples.display),
                "keystrokeMedian": Self.median(samples.keystroke),
                "keystrokeP95": Self.percentile(samples.keystroke, 0.95),
                "keystrokeMax": samples.keystroke.max() ?? 0,
                "scrollLayoutMedian": Self.median(samples.scrollLayout),
                "scrollLayoutP95": Self.percentile(samples.scrollLayout, 0.95),
                "scrollDisplayMedian": Self.median(samples.scrollDisplay),
                "keystrokes": samples.keystroke.count,
                "gutterDrawMedian": Self.median(samples.gutterDraw),
                "gutterDrawP95": Self.percentile(samples.gutterDraw, 0.95),
                "gutterDrawsDuringTyping": samples.gutterDrawsDuringTyping,
                "scrollGutterDrawMedian": Self.median(samples.scrollGutterDraw),
                "scrollGutterDrawP95": Self.percentile(samples.scrollGutterDraw, 0.95),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("Line-number cost probe at \(position): \(String(bytes: data, encoding: .utf8) ?? "")")
    }

    private func measure(_ source: String, lineNumbers: Bool, position: Double) throws -> Samples {
        let editor = try makeEditor()
        let (window, scrollView, textView) = (editor.window, editor.scrollView, editor.textView)
        defer { window.close() }
        let delegate = makeEditDelegate()
        textView.textDelegate = delegate
        textView.text = source
        setLineNumbers(lineNumbers, in: textView)
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let target = Int(Double(source.utf16.count) * position)
        let caretLine = (source as NSString).lineRange(for: NSRange(location: target, length: 0))
        textView.textSelection = NSRange(location: caretLine.location, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        var samples = Samples()
        measureTyping(in: textView, window: window, into: &samples)
        measureScrolling(in: textView, scrollView: scrollView, window: window, into: &samples)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.length, source.utf16.count + 45)
        withExtendedLifetime(delegate) {}
        return samples
    }

    private struct Editor {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
    }

    private func makeEditor() throws -> Editor {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.25
        textView.defaultParagraphStyle = paragraphStyle
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        return Editor(window: window, scrollView: scrollView, textView: textView)
    }

    private func measureTyping(in textView: MarkdownSTTextView, window: NSWindow, into samples: inout Samples) {
        let drawsBeforeTyping = gutterDrawCount(textView)
        for keystroke in 0 ..< 45 {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText("a", replacementRange: textView.selectedRange())
            let inserted = DispatchTime.now().uptimeNanoseconds
            textView.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            window.displayIfNeeded()
            let displayed = DispatchTime.now().uptimeNanoseconds
            // The first keystrokes warm caches; every later one is measured.
            guard keystroke >= 5 else { continue }
            samples.insert.append(Self.milliseconds(start, inserted))
            samples.layout.append(Self.milliseconds(inserted, laidOut))
            samples.display.append(Self.milliseconds(laidOut, displayed))
            samples.keystroke.append(Self.milliseconds(start, displayed))
            if let draw = forcedGutterDrawMilliseconds(textView) {
                samples.gutterDraw.append(draw)
            }
        }
        samples.gutterDrawsDuringTyping.append(Double(gutterDrawCount(textView) - drawsBeforeTyping))
    }

    private func measureScrolling(
        in textView: MarkdownSTTextView,
        scrollView: NSScrollView,
        window: NSWindow,
        into samples: inout Samples
    ) {
        let origin = scrollView.contentView.bounds.origin.y
        for step in 0 ..< 80 {
            let distance = CGFloat(step < 40 ? step : 79 - step) * 12
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin + distance))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let start = DispatchTime.now().uptimeNanoseconds
            textView.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            window.displayIfNeeded()
            let displayed = DispatchTime.now().uptimeNanoseconds
            samples.scrollLayout.append(Self.milliseconds(start, laidOut))
            samples.scrollDisplay.append(Self.milliseconds(laidOut, displayed))
            if let draw = forcedGutterDrawMilliseconds(textView) {
                samples.scrollGutterDraw.append(draw)
            }
        }
    }

    // MARK: - Tree-specific: EditorKit's gutter

    private func setLineNumbers(_ visible: Bool, in textView: MarkdownSTTextView) {
        textView.setLineNumberGutterStyle(visible ? EditorLineNumberGutterView.Style(
            font: MarkdownSyntaxHighlighter.defaultFont,
            textColor: .secondaryLabelColor,
            currentLineTextColor: .labelColor
        ) : nil)
    }

    /// Forwards native edits to the shared line index, as `MarkdownTextViewCoordinator`
    /// does in the app.
    @MainActor
    private final class LineIndexEditForwarder: @preconcurrency STTextViewDelegate {
        func textView(_ textView: STTextView, willChangeTextIn range: NSTextRange, replacementString: String) {
            (textView as? MarkdownSTTextView)?.lineIndexCache.textWillChange(
                in: NSRange(range, in: textView.textContentManager),
                replacementString: replacementString
            )
        }
    }

    private func makeEditDelegate() -> STTextViewDelegate? {
        LineIndexEditForwarder()
    }

    private func gutterDrawCount(_ textView: MarkdownSTTextView) -> Int {
        textView.lineNumberGutter?.drawCount ?? 0
    }

    /// The window server may not display a test process's windows, so the gutter draws
    /// into a bitmap and reports its own `draw(_:)` time next to the keystroke.
    private func forcedGutterDrawMilliseconds(_ textView: MarkdownSTTextView) -> Double? {
        guard let gutter = textView.lineNumberGutter,
              let rep = gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds)
        else {
            return nil
        }
        gutter.cacheDisplay(in: gutter.bounds, to: rep)
        return gutter.lastDrawMilliseconds
    }

    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}
