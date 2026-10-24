import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Opt-in (PLAINSONG_RUN_WYSIWYG_CLICK_PROBE=1) cost of a pointer click in Experimental
/// WYSIWYG on `Fixtures/large-1mb.md`, near the top, middle and end, with the visible range
/// folded and image thumbnails placed. Run release-optimized:
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
        var clicks = 0
        var offLine: [String] = []

        mutating func append(_ other: Self) {
            firstClick += other.firstClick
            click += other.click
            frameAfterClick += other.frameAfterClick
            keystrokeAfterClick += other.keystrokeAfterClick
            snapLookup += other.snapLookup
            clicks += other.clicks
            offLine += other.offLine
        }
    }

    private struct Target {
        let name: String
        let offset: Int
        /// The clicked line without its line break.
        let line: NSRange
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
                "clicks": samples.clicks,
                "offLine": samples.offLine,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("WYSIWYG click cost probe: \(String(bytes: data, encoding: .utf8) ?? "")")
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
            if !(target.line.location ... NSMaxRange(target.line)).contains(caret) {
                samples.offLine.append("\(target.name)@\(target.offset) in \(target.line) -> \(caret)")
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
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        return samples
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
                    targets.append(Target(name: name, offset: offset, line: Self.line(at: offset, in: storage)))
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
                targets.append(Target(name: "line", offset: offset, line: line))
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
