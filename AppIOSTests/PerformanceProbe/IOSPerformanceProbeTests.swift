@testable import PlainsongIOS
import UIKit
import XCTest

@MainActor
final class IOSPerformanceProbeTests: XCTestCase {
    func testSummaryUsesNearestRankSoEveryValueWasMeasured() throws {
        let hundred = try XCTUnwrap(IOSPerformanceSummary.of((1 ... 100).map(Double.init).reversed()))
        XCTAssertEqual(hundred, IOSPerformanceSummary(count: 100, median: 50, p95: 95, maximum: 100))
        let sixty = try XCTUnwrap(IOSPerformanceSummary.of((1 ... 60).map(Double.init)))
        XCTAssertEqual(sixty.p95, 57)
        XCTAssertEqual(
            IOSPerformanceSummary.of([4.5]),
            IOSPerformanceSummary(count: 1, median: 4.5, p95: 4.5, maximum: 4.5)
        )
        XCTAssertNil(IOSPerformanceSummary.of([]))
    }

    func testCaretOffsetsStayOnLineAndCharacterBoundaries() {
        let text = "# Title\n\nfirst 👨‍👩‍👧 line\nsecond line\nthird line\n"
        let source = text as NSString
        XCTAssertEqual(IOSPerformanceProbe.caretOffset(.start, in: text), 0)
        XCTAssertEqual(IOSPerformanceProbe.caretOffset(.end, in: text), source.length)
        let middle = IOSPerformanceProbe.caretOffset(.middle, in: text)
        XCTAssertEqual(source.lineRange(for: NSRange(location: middle, length: 0)).location, middle)
        XCTAssertTrue(middle > 0 && middle < source.length)
        XCTAssertEqual(IOSPerformanceProbe.caretOffset(.middle, in: ""), 0)
    }

    func testReportNamesEveryReasonARunCannotBeUsed() {
        var report = makeReport(samples: 60)
        report.summarize()
        XCTAssertTrue(report.isAdmissible, "\(report.inadmissibleReasons)")

        report = makeReport(samples: 59)
        report.environment.buildConfiguration = "Debug"
        report.environment.lowPowerMode = true
        report.environment.thermalStateAtEnd = "serious"
        report.documentRestored = false
        report.summarize()
        XCTAssertEqual(report.inadmissibleReasons.count, 5)
        XCTAssertFalse(report.isAdmissible)
    }

    func testBudgetsCompareP95AndSkipMetricsWithoutSamples() throws {
        var report = makeReport(samples: 60, commit: 20, highlight: nil)
        report.summarize()
        XCTAssertEqual(report.budgets.map(\.metric), ["keystroke commit"])
        XCTAssertEqual(report.budgets.first?.withinBudget, false)
        XCTAssertEqual(report.highlightMissing, 60)
        XCTAssertNil(report.previewRender)

        let decoded = try JSONDecoder.iso8601.decode(IOSPerformanceReport.self, from: report.encodedJSON())
        XCTAssertEqual(decoded.typing, report.typing)
        XCTAssertEqual(decoded.budgets, report.budgets)
    }

    func testRunTypesMeasuresAndRestoresTheDocument() async throws {
        let host = ProbeHost(text: "# Title\n\nbody 👨‍👩‍👧 text\nlast line\n")
        var highlight: (() -> Void)?
        var target = host.target()
        target.setHighlightObserver = { highlight = $0 }
        let probe = IOSPerformanceProbe()
        probe.target = { target }
        probe.configuration = .fast(samples: 5)
        host.onChange = { highlight?() }

        let report = try await probe.run()

        XCTAssertEqual(host.textView.text, host.original)
        XCTAssertTrue(report.documentRestored)
        XCTAssertEqual(report.typing.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(host.insertions, 7, "Two warm-up keystrokes are typed and not reported")
        for sample in report.typing {
            XCTAssertGreaterThanOrEqual(sample.insertMilliseconds, 0)
            XCTAssertGreaterThanOrEqual(sample.commitMilliseconds, sample.insertMilliseconds)
            XCTAssertGreaterThanOrEqual(sample.refreshMilliseconds, sample.commitMilliseconds)
            XCTAssertNotNil(sample.highlightMilliseconds)
        }
        XCTAssertEqual(report.document.utf16Length, (host.original as NSString).length)
        XCTAssertEqual(report.document.sha256.count, 64)
        XCTAssertNil(highlight, "The run removes its observers")
        XCTAssertEqual(report.preview, [])
        XCTAssertTrue(report.inadmissibleReasons.contains { $0.contains("Only 5 keystroke samples") })
    }

    func testRefusedKeystrokeStopsTheRunAndLeavesTheTextAlone() async {
        let host = ProbeHost(text: "alpha\nbeta\n")
        host.refusesAfter = 3
        let probe = IOSPerformanceProbe()
        probe.target = { host.target() }
        probe.configuration = .fast(samples: 5)
        do {
            _ = try await probe.run()
            XCTFail("A refused keystroke must stop the run")
        } catch {
            XCTAssertEqual(error as? IOSPerformanceProbeFailure, .keystrokeRefused)
        }
        XCTAssertEqual(host.textView.text, host.original)
    }

    func testReadOnlyAndMissingDocumentsAreRefusedBeforeTyping() async {
        let host = ProbeHost(text: "alpha")
        let probe = IOSPerformanceProbe()
        probe.target = { host.target(canWrite: false) }
        await assertFailure(probe, .readOnly)
        probe.target = { nil }
        await assertFailure(probe, .noDocument)
        XCTAssertEqual(host.insertions, 0)
        XCTAssertEqual(host.textView.text, "alpha")
    }

    func testReportFileIsWrittenAsJSON() throws {
        var report = makeReport(samples: 60)
        report.summarize()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(IOSPerformanceReportFile(report: report, directory: directory))
        XCTAssertEqual(file.url.lastPathComponent, "plainsong-ios-perf-20261115-000000.json")
        let decoded = try JSONDecoder.iso8601.decode(IOSPerformanceReport.self, from: Data(contentsOf: file.url))
        XCTAssertEqual(decoded, report)
    }

    private func assertFailure(
        _ probe: IOSPerformanceProbe,
        _ expected: IOSPerformanceProbeFailure,
        line: UInt = #line
    ) async {
        do {
            _ = try await probe.run()
            XCTFail("Expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? IOSPerformanceProbeFailure, expected, line: line)
        }
    }

    private func makeReport(samples: Int, commit: Double = 4, highlight: Double? = 30) -> IOSPerformanceReport {
        IOSPerformanceReport(
            environment: IOSPerformanceEnvironment(
                deviceModel: "iPhone15,2",
                systemVersion: "27.0",
                appVersion: "1.0",
                appBuild: "1",
                buildConfiguration: "Release",
                maximumFramesPerSecond: 120,
                frameIntervalMilliseconds: 8.3,
                thermalStateAtStart: "nominal",
                thermalStateAtEnd: "fair",
                lowPowerMode: false,
                editorWasFirstResponder: true,
                previewWasVisible: false,
                startedAt: Date(timeIntervalSince1970: 1_794_700_800)
            ),
            document: IOSPerformanceDocument(
                name: "perf-100kb.md",
                fileKind: "markdown",
                utf8Bytes: 100_000,
                utf16Length: 99000,
                sha256: String(repeating: "a", count: 64),
                caretUTF16Offset: 49000
            ),
            configuration: IOSPerformanceProbeConfiguration(),
            typing: (0 ..< samples).map {
                IOSPerformanceTypingSample(
                    index: $0,
                    insertMilliseconds: 1,
                    commitMilliseconds: commit,
                    refreshMilliseconds: commit + 4,
                    highlightMilliseconds: highlight
                )
            },
            preview: [],
            previewTimeouts: 0,
            documentRestored: true,
            highlightMissing: 0,
            budgets: [],
            inadmissibleReasons: []
        )
    }
}

private extension IOSPerformanceProbeConfiguration {
    static func fast(samples: Int) -> IOSPerformanceProbeConfiguration {
        var configuration = IOSPerformanceProbeConfiguration()
        configuration.warmUpCount = 2
        configuration.sampleCount = samples
        configuration.keystrokeIntervalMilliseconds = 10
        configuration.highlightWaitMilliseconds = 40
        configuration.previewSampleCount = 0
        return configuration
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A text view in a real window, so layout, the run loop commit and the display link run.
/// UIKit does not ask the delegate about a programmatic `insertText`, so the counting and
/// the refusal sit in an override, where the production text view has its own check.
@MainActor
private final class ProbeHost: NSObject, UITextViewDelegate {
    final class TextView: UITextView {
        var refusesAfter: Int?
        private(set) var insertions = 0

        override func insertText(_ text: String) {
            if let refusesAfter, insertions >= refusesAfter {
                return
            }
            insertions += 1
            super.insertText(text)
        }
    }

    let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let original: String
    var onChange: (() -> Void)?

    var insertions: Int {
        textView.insertions
    }

    var refusesAfter: Int? {
        get { textView.refusesAfter }
        set { textView.refusesAfter = newValue }
    }

    init(text: String) {
        original = text
        super.init()
        textView.text = text
        textView.delegate = self
        let controller = UIViewController()
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.isHidden = false
    }

    func target(canWrite: Bool = true) -> IOSPerformanceProbeTarget {
        IOSPerformanceProbeTarget(
            textView: textView,
            documentName: "probe.md",
            fileKind: "markdown",
            canWrite: canWrite
        )
    }

    func textViewDidChange(_: UITextView) {
        onChange?()
    }
}
