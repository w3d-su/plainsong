import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class MarkdownHighlightContentionProbeTests: XCTestCase {
    private static let warmupBursts = 6
    private static let measuredBursts = 48
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")

    private struct Sample {
        let submitted: UInt64
        let entered: UInt64
        let finished: UInt64
        let appliedMilliseconds: Double
    }

    private struct Editor {
        let textView: MarkdownSTTextView
        let editLocation: Int
        let request: NSRange
        let service: MarkdownHighlightService
    }

    func testConcurrentSourceHighlighting() async throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_HIGHLIGHT_CONTENTION_PROBE"] == "1" else {
            throw XCTSkip("Set PLAINSONG_RUN_HIGHLIGHT_CONTENTION_PROBE=1 to measure highlight contention")
        }
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/perf-500kb.md")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)

        print("highlight_probe,bytes,editors,mode,samples,requests_per_second,"
            + "latency_p50_ms,latency_p95_ms,latency_max_ms,wait_p50_ms,wait_p95_ms,wait_max_ms,"
            + "compute_p50_ms,compute_p95_ms,compute_max_ms,apply_p50_ms,apply_p95_ms,apply_max_ms")
        for size in [5 * 1024, 200 * 1024] {
            let prefix = fixture.utf8.prefix(size)
            let end = try XCTUnwrap(prefix.lastIndex(of: 0x0A))
            let source = try XCTUnwrap(String(bytes: prefix[...end], encoding: .utf8))
            for (index, count) in [1, 2, 4, 8].enumerated() {
                let modes = index.isMultiple(of: 2) ? [true, false] : [false, true]
                for shared in modes {
                    try await measure(source: source, count: count, shared: shared)
                }
            }
        }
    }

    private func measure(source: String, count: Int, shared: Bool) async throws {
        let service = shared ? MarkdownHighlightService() : nil
        let plainText = source as NSString
        let midpoint = plainText.length / 2
        let prose = plainText.range(
            of: "ordinary prose",
            options: [],
            range: NSRange(location: midpoint, length: plainText.length - midpoint)
        )
        let editLocation = try XCTUnwrap(prose.location == NSNotFound ? nil : NSMaxRange(prose))
        let visibleRange = NSRange(location: max(0, prose.location - 1000), length: 2200)
        let request = MarkdownEditorView.highlightRequestRange(visibleRange: visibleRange, selection: nil)
        let editors = (0 ..< count).map { _ in
            let textView = MarkdownSTTextView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            textView.text = source
            return Editor(
                textView: textView,
                editLocation: editLocation,
                request: request,
                service: service ?? MarkdownHighlightService()
            )
        }

        var samples: [Sample] = []
        var serviceSpan: UInt64 = 0
        for round in 0 ..< Self.warmupBursts + Self.measuredBursts {
            let burst = try await runBurst(editors: editors, round: round)
            guard round >= Self.warmupBursts else { continue }
            samples += burst
            serviceSpan += try XCTUnwrap(burst.map(\.finished).max()) - XCTUnwrap(burst.map(\.submitted).min())
        }
        XCTAssertEqual(samples.count, count * Self.measuredBursts)
        let throughput = Double(samples.count) / (Double(serviceSpan) / 1_000_000_000)
        let latency = samples.map { Self.milliseconds($0.finished - $0.submitted) }
        let wait = samples.map { Self.milliseconds($0.entered - $0.submitted) }
        let compute = samples.map { Self.milliseconds($0.finished - $0.entered) }
        let mode = shared ? "shared" : "independent"
        let metrics = [String(format: "%.1f", throughput)]
            + [latency, wait, compute, samples.map(\.appliedMilliseconds)].flatMap(Self.summary)
        print((["highlight_probe", String(source.utf8.count), String(count), mode, String(samples.count)]
                + metrics).joined(separator: ","))
    }

    private func runBurst(editors: [Editor], round: Int) async throws -> [Sample] {
        let sources = try editors.enumerated().map { index, editor in
            let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor.textView))
            let location = editor.editLocation + round
            let letter = Self.letters[(round + index) % Self.letters.count]
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: String(letter))
            editor.textView.textSelection = NSRange(location: location + 1, length: 0)
            return try XCTUnwrap(ExactSourceText.nativeCopy(of: storage.string as NSString))
        }
        let tasks = zip(editors, sources).map { editor, source in
            let service = editor.service
            let request = editor.request
            return Task { @MainActor in
                let submitted = DispatchTime.now().uptimeNanoseconds
                let measured = await service.probeHighlight(source, request: request)
                return (submitted: submitted, measured: measured)
            }
        }
        var completed: [(submitted: UInt64, measured: HighlightTiming)] = []
        for task in tasks {
            let entry = await task.value
            completed.append(entry)
        }
        return zip(editors, completed).map { editor, entry in
            let highlighted = entry.measured.result
            let styled = HighlightedText(revision: round, range: highlighted.range, text: highlighted.text)
            let started = DispatchTime.now().uptimeNanoseconds
            let applied = MarkdownTextView.applyHighlightedText(styled, to: editor.textView)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            XCTAssertTrue(applied)
            XCTAssertGreaterThan(highlighted.text.runs.count, 1)
            return Sample(
                submitted: entry.submitted,
                entered: entry.measured.entered,
                finished: entry.measured.finished,
                appliedMilliseconds: Self.milliseconds(elapsed)
            )
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func summary(_ samples: [Double]) -> [String] {
        let ordered = samples.sorted()
        return [0.50, 0.95, 1.0].map { percentile in
            let index = Int((Double(ordered.count) * percentile).rounded(.up)) - 1
            return String(format: "%.3f", ordered[index])
        }
    }
}

private struct HighlightTiming {
    let entered: UInt64
    let finished: UInt64
    let result: MarkdownHighlightResult
}

private extension MarkdownHighlightService {
    func probeHighlight(_ source: String, request: NSRange) -> HighlightTiming {
        let entered = DispatchTime.now().uptimeNanoseconds
        let result = highlight(
            source,
            fileKind: .markdown,
            visibleRange: request,
            theme: .standard,
            fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
            fontSize: 13
        )
        return HighlightTiming(entered: entered, finished: DispatchTime.now().uptimeNanoseconds, result: result)
    }
}
