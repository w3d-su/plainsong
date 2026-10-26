import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Opt-in (PLAINSONG_RUN_WYSIWYG_CLICK_PROBE=1) cost of a pointer click in Experimental
/// WYSIWYG on `Fixtures/large-1mb.md`, near the top, middle and end, with the visible range
/// folded and image thumbnails placed, plus one click after a scroll with no layout pass.
/// Run release-optimized:
/// `PLAINSONG_RUN_WYSIWYG_CLICK_PROBE=1 swift test -c release -Xswiftc -enable-testing
/// --filter WYSIWYGPointerClickCostProbeTests`. Loaded-machine timings are diagnostics.
@MainActor
final class WYSIWYGPointerClickCostProbeTests: XCTestCase {
    private struct Samples {
        /// The first click after scrolling there; later clicks find earlier layout cached.
        var firstClick: [Double] = []
        var click: [Double] = []
        /// Layout and display of the frame after a click.
        var frameAfterClick: [Double] = []
        /// One keystroke right after the first click, through display.
        var keystrokeAfterClick: [Double] = []
        /// The caret snap lookup a click runs (fold and image attribute runs), timed on its own.
        var snapLookup: [Double] = []
        /// A click a screen and a half from the laid-out viewport, before a layout pass.
        var staleClick: [Double] = []
        var clicks = 0
        /// Clicks whose caret is not at the clicked character (or, for the stale click,
        /// not where the laid-out viewport maps the point).
        var missed: [String] = []

        mutating func append(_ other: Self) {
            firstClick += other.firstClick
            click += other.click
            frameAfterClick += other.frameAfterClick
            keystrokeAfterClick += other.keystrokeAfterClick
            snapLookup += other.snapLookup
            staleClick += other.staleClick
            clicks += other.clicks
            missed += other.missed
        }
    }

    private struct Target {
        let name: String
        let offset: Int
        /// The clicked character's composed sequence: a caret at either edge is on target.
        let character: NSRange
    }

    func testPointerClickCostOnLargeFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLAINSONG_RUN_WYSIWYG_CLICK_PROBE"] == "1" else {
            throw XCTSkip("WYSIWYG click cost probe is opt-in: PLAINSONG_RUN_WYSIWYG_CLICK_PROBE=1")
        }
        let source = try String(contentsOf: WYSIWYGPointerClickTestSupport.largeFixture, encoding: .utf8)
        let rounds = Int(environment["PLAINSONG_WYSIWYG_CLICK_PROBE_ROUNDS"] ?? "") ?? 3
        let positions: [(name: String, fraction: Double)] = [("top", 0), ("middle", 0.5), ("end", 1)]
        var samples: [String: Samples] = [:]
        for round in 0 ..< rounds {
            for position in round.isMultiple(of: 2) ? positions : positions.reversed() {
                let measured = try measure(source, fraction: position.fraction)
                samples[position.name, default: Samples()].append(measured)
            }
        }

        var report: [String: Any] = [:]
        for (name, samples) in samples {
            report[name] = [
                "firstClickMedian": Self.median(samples.firstClick),
                "firstClickMax": samples.firstClick.max() ?? 0,
                "clickMedian": Self.median(samples.click),
                "clickP95": Self.percentile(samples.click, 0.95),
                "clickMax": samples.click.max() ?? 0,
                "frameAfterClickMedian": Self.median(samples.frameAfterClick),
                "keystrokeAfterClickMedian": Self.median(samples.keystrokeAfterClick),
                "keystrokeAfterClickMax": samples.keystrokeAfterClick.max() ?? 0,
                "snapLookupMedian": Self.median(samples.snapLookup),
                "snapLookupMax": samples.snapLookup.max() ?? 0,
                "staleClickMedian": Self.median(samples.staleClick),
                "staleClickMax": samples.staleClick.max() ?? 0,
                "clicks": samples.clicks,
                "missed": samples.missed,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("WYSIWYG click cost probe: \(String(bytes: data, encoding: .utf8) ?? "")")
        XCTAssertEqual(samples.values.flatMap(\.missed), [], "every click lands on the clicked character")
    }

    private func measure(_ source: String, fraction: Double) throws -> Samples {
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(source)
        defer { editor.window.close() }
        let textView = editor.textView
        try WYSIWYGPointerClickTestSupport.scroll(editor, toFraction: fraction, source: source)
        let viewport = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: textView))
        WYSIWYGPointerClickTestSupport.placeImageThumbnails(editor, in: viewport, source: source)

        let targets = clickTargets(in: editor, source: source)
        XCTAssertGreaterThanOrEqual(targets.count, 8, "visible click targets at \(fraction)")
        var samples = Samples()
        for (index, target) in targets.enumerated() {
            // Positions are read just before each click: revealing an image relays out its line.
            guard let point = WYSIWYGPointerClickTestSupport.visiblePoint(ofCharacterAt: target.offset, in: editor)
            else {
                continue
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let caret = try WYSIWYGPointerClickTestSupport.click(at: point, in: editor)
            let clicked = DispatchTime.now().uptimeNanoseconds
            WYSIWYGPointerClickTestSupport.settle(editor.window, textView)
            let framed = DispatchTime.now().uptimeNanoseconds
            if index == 0 {
                samples.firstClick.append(Self.milliseconds(start, clicked))
            } else {
                samples.click.append(Self.milliseconds(start, clicked))
            }
            samples.frameAfterClick.append(Self.milliseconds(clicked, framed))
            samples.clicks += 1
            if !(target.character.location ... NSMaxRange(target.character)).contains(caret) {
                samples.missed.append("\(target.name)@\(target.offset) -> \(caret)")
            }

            let lookupStart = DispatchTime.now().uptimeNanoseconds
            _ = textView.wysiwygSnappedCaretOffset(caret, preferring: .nearest)
            samples.snapLookup.append(Self.milliseconds(lookupStart, DispatchTime.now().uptimeNanoseconds))

            if index == 0 {
                let typed = DispatchTime.now().uptimeNanoseconds
                textView.insertText("a", replacementRange: textView.selectedRange())
                WYSIWYGPointerClickTestSupport.settle(editor.window, textView)
                samples.keystrokeAfterClick.append(Self.milliseconds(typed, DispatchTime.now().uptimeNanoseconds))
                textView.deleteBackward(nil)
                WYSIWYGPointerClickTestSupport.settle(editor.window, textView)
            }
        }
        try measureStaleClick(in: editor, samples: &samples)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        return samples
    }

    /// Scrolls a screen and a half (down, or up at the end) without a layout pass and clicks
    /// the middle of the visible area, which the viewport no longer encloses. Once the next
    /// layout pass has laid out the viewport there, it must map the point to the same caret.
    private func measureStaleClick(in editor: WYSIWYGPointerClickTestSupport.Editor, samples: inout Samples) throws {
        let textView = editor.textView
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let distance = textView.visibleRect.height * 1.5
        let down = textView.visibleRect.maxY + distance < textView.bounds.maxY
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clipView.bounds.minY + (down ? distance : -distance)))
        textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        let windowPoint = textView.convert(
            CGPoint(x: textView.visibleRect.minX + 120, y: textView.visibleRect.midY),
            to: nil
        )
        let scrolledTo = clipView.bounds.minY

        let start = DispatchTime.now().uptimeNanoseconds
        let caret = try WYSIWYGPointerClickTestSupport.click(at: windowPoint, in: editor)
        samples.staleClick.append(Self.milliseconds(start, DispatchTime.now().uptimeNanoseconds))
        WYSIWYGPointerClickTestSupport.settle(editor.window, textView)

        // The same window point: the layout pass may have moved the scroll origin.
        let viewPoint = textView.convert(windowPoint, from: nil)
        let containerPoint = CGPoint(x: viewPoint.x - (textView.gutterView?.frame.width ?? 0), y: viewPoint.y)
        let laidOut = WYSIWYGPointerHitTest.characterIndex(at: containerPoint, in: textView)
        let mapped = laidOut.offset.map { textView.wysiwygSnappedCaretOffset($0, preferring: .nearest) }
        if laidOut.laidOutBand || mapped != caret {
            let scrolled = clipView.bounds.minY - scrolledTo
            let laidOutCaret = String(describing: mapped)
            samples.missed.append("stale click -> \(caret), laid out \(laidOutCaret), scrolled \(scrolled)")
        }
    }

    /// Folded constructs first (bold, link text, heading, the line of an image thumbnail),
    /// then the middle of each visible line.
    private func clickTargets(in editor: WYSIWYGPointerClickTestSupport.Editor, source: String) -> [Target] {
        let storage = source as NSString
        guard let top = EditorVisibleTop.utf16Offset(in: editor.textView) else { return [] }
        var targets: [Target] = []
        for (name, text) in [
            ("bold", "bold text"),
            ("link", "a relative link"),
            ("heading", "## Section "),
            ("image line", "image reference"),
            ("task", "Task item"),
        ] {
            var search = NSRange(location: top, length: storage.length - top)
            while case let found = storage.range(of: text, options: [], range: search), found.location != NSNotFound {
                let offset = found.location + found.length - 3
                if WYSIWYGPointerClickTestSupport.visiblePoint(ofCharacterAt: offset, in: editor) != nil {
                    targets.append(Target(
                        name: name,
                        offset: offset,
                        character: storage.rangeOfComposedCharacterSequence(at: offset)
                    ))
                    break
                }
                guard found.location < top + 20000 else { break }
                search = NSRange(location: NSMaxRange(found), length: storage.length - NSMaxRange(found))
            }
        }

        var lineStart = storage.lineRange(for: NSRange(location: top, length: 0)).location
        while lineStart < storage.length, targets.count < 24 {
            let line = Self.line(at: lineStart, in: storage)
            defer { lineStart = NSMaxRange(storage.lineRange(for: NSRange(location: lineStart, length: 0))) }
            guard line.length >= 3 else { continue }
            let middle = line.location + line.length / 2
            let candidates = middle ..< min(NSMaxRange(line), middle + 24)
            if let offset = candidates.first(where: {
                WYSIWYGPointerClickTestSupport.visiblePoint(ofCharacterAt: $0, in: editor) != nil
            }) {
                targets.append(Target(
                    name: "line",
                    offset: offset,
                    character: storage.rangeOfComposedCharacterSequence(at: offset)
                ))
            } else if WYSIWYGPointerClickTestSupport.visiblePoint(ofCharacterAt: line.location, in: editor) == nil,
                      line.location > top + 2000
            {
                break
            }
        }
        return targets
    }

    private static func line(at offset: Int, in storage: NSString) -> NSRange {
        var line = storage.lineRange(for: NSRange(location: offset, length: 0))
        while line.length > 0, [0x0A, 0x0D].contains(storage.character(at: NSMaxRange(line) - 1)) {
            line.length -= 1
        }
        return line
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
