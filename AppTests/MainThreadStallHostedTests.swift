import AppKit
@testable import EditorKit
@testable import Plainsong
import XCTest

/// Opt-in (TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1) main-thread diagnostics for typing
/// with the live preview. The typing gates time only the synchronous native insertion;
/// this records every busy stretch of the main run loop, including SwiftUI updates,
/// highlight application and preview payload work that a keystroke schedules.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedSourcePreviewTypingMainThreadBusySlices() async throws {
        try await recordTypingBusySlices(layoutMode: .sourcePreview, visitingDocumentEnd: false)
    }

    /// Viewing the end once leaves TextKit's element cache filled to there (see
    /// `EditorTextElementCacheTrimmer`); typing above it is the common case afterwards.
    func testHostedSourcePreviewTypingAfterViewingDocumentEndMainThreadBusySlices() async throws {
        try await recordTypingBusySlices(layoutMode: .sourcePreview, visitingDocumentEnd: true)
    }

    /// The same workload without the preview, whose layer-tree commits dominate the
    /// slices above and vary between runs: what remains is the editor's own work.
    func testHostedSourceOnlyTypingMainThreadBusySlices() async throws {
        try await recordTypingBusySlices(layoutMode: .sourceOnly, visitingDocumentEnd: false)
    }

    private func recordTypingBusySlices(layoutMode: EditorLayoutMode, visitingDocumentEnd: Bool) async throws {
        try requireScrollProbe()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let lineNumbers = scrollProbeShowsLineNumbers
        let environment = ProcessInfo.processInfo.environment
        let requestedChunks = environment["PLAINSONG_SCROLL_PROBE_TRIM_CHUNKS"].flatMap { $0.isEmpty ? nil : $0 }
        let trimChunks = try requestedChunks.map { value in
            try XCTUnwrap(Int(value).flatMap { $0 >= 0 ? $0 : nil }, "Trim chunk count must be nonnegative")
        }
        let trimYieldMilliseconds = try environment["PLAINSONG_SCROLL_PROBE_TRIM_YIELD_MS"].map { value in
            try XCTUnwrap(Int(value).flatMap { $0 >= 0 && $0 <= Int.max / 1_000_000 ? $0 : nil },
                          "Trim yield milliseconds must be nonnegative and representable as nanoseconds")
        } ?? 0
        let hideGutterDraw = environment["PLAINSONG_SCROLL_PROBE_HIDE_GUTTER_DRAW"] == "1"
        let useAdmission = environment["PLAINSONG_SCROLL_PROBE_USE_ADMISSION"] == "1"
        let requestedWidth = environment["PLAINSONG_SCROLL_PROBE_WINDOW_WIDTH"].flatMap { $0.isEmpty ? nil : $0 }
        let windowWidth = try requestedWidth.map { value in
            try XCTUnwrap(Double(value).flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                          "Window width must be finite and positive")
        } ?? 1000
        let hosted = try await makeHostedEditorWorkspace(
            source: source,
            layoutMode: layoutMode,
            showsLineNumbers: lineNumbers,
            windowWidth: CGFloat(windowWidth)
        )
        let editor = try hostedEditor(hosted)
        let hideGutterEarly = environment["PLAINSONG_SCROLL_PROBE_HIDE_GUTTER_EARLY"] == "1"
        if hideGutterEarly {
            editor.lineNumberGutter?.isHidden = true
        }
        let tracedTrimmer = environment["PLAINSONG_SCROLL_PROBE_TRIM_TRACE"] == "1"
            ? (editor.textDelegate as? MarkdownTextViewCoordinator)?.textElementCacheTrimmer : nil
        let trimmerEvents = tracedTrimmer.map { _ in TypingProbeTrimmerEvents(editor: editor) }
        tracedTrimmer?.probeHandler = { [weak trimmerEvents] event, range in
            trimmerEvents?.record(event, range: range)
        }
        defer { tracedTrimmer?.probeHandler = nil }
        let paragraphSpy = environment["PLAINSONG_SCROLL_PROBE_PARAGRAPH_TRACE"] == "1"
            ? TypingProbeParagraphRequests(
                viewport: MarkdownTextView.visibleTextRange(of: editor),
                captureBeyondLocation: Int(environment["PLAINSONG_SCROLL_PROBE_CAPTURE_BEYOND_OFFSET"] ?? "")
            ) : nil
        let contentStorage = editor.textContentManager as? NSTextContentStorage
        let previousDelegate = contentStorage?.delegate
        if let paragraphSpy {
            contentStorage?.delegate = try XCTUnwrap(
                previousDelegate == nil ? paragraphSpy : nil,
                "Paragraph tracing requires the default NSTextContentStorage paragraph provider"
            )
        }
        defer {
            if paragraphSpy != nil {
                contentStorage?.delegate = previousDelegate
            }
        }
        let trimmer: EditorTextElementCacheTrimmer? = if trimChunks != nil {
            try XCTUnwrap((editor.textDelegate as? MarkdownTextViewCoordinator)?.textElementCacheTrimmer)
        } else {
            nil
        }
        trimmer?.cancel()
        if layoutMode == .sourcePreview {
            try await waitForLargePreview(hosted)
        }
        let middle = (source as NSString).lineRange(for: NSRange(location: source.utf16.count / 2, length: 0))
        let trimScrollAfter = Int(environment["PLAINSONG_SCROLL_PROBE_TRIM_SCROLL_AFTER"] ?? "") ?? -1
        if let delay = UInt64(environment["PLAINSONG_SCROLL_PROBE_TOP_SETTLE_MS"] ?? "") {
            try await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        var scrolledDuringTrim = false
        var explicitTrimRanges: [[String: Int]] = []
        if let trimChunks {
            // Match an interrupted top-of-document trim exactly, without depending on
            // which run-loop turn admits the 400 ms production settle task.
            try await settleTypingProbe(nanoseconds: 300_000_000, cancelling: trimmer)
            let length = try XCTUnwrap(MarkdownTextView.textStorage(of: editor)?.length)
            let count = try XCTUnwrap(
                trimChunks <= length / EditorTextElementCacheTrimmer.chunkLength ? trimChunks : nil,
                "Requested trim chunks exceed the fixture length"
            )
            if environment["PLAINSONG_SCROLL_PROBE_USE_PRODUCTION_TRIM"] == "1" {
                explicitTrimRanges = try await TypingProbePreparation.productionTrim(
                    chunks: count,
                    navigatingAfter: trimScrollAfter,
                    to: NSRange(location: middle.location, length: 0),
                    in: editor
                )
                scrolledDuringTrim = trimScrollAfter > 0
            } else {
                let prepared = try await TypingProbePreparation.manualTrim(
                    .init(
                        chunks: count,
                        initialLength: length,
                        navigatingAfter: trimScrollAfter,
                        navigationRange: NSRange(location: middle.location, length: 0),
                        yieldMilliseconds: trimYieldMilliseconds,
                        drawAfterTrim: Int(environment["PLAINSONG_SCROLL_PROBE_DRAW_AFTER_TRIM"] ?? ""),
                        layoutBetweenTrims: environment["PLAINSONG_SCROLL_PROBE_TRIM_LAYOUT"] == "1",
                        useAdmission: useAdmission
                    ),
                    in: editor,
                    cancelling: trimmer
                )
                explicitTrimRanges = prepared.ranges
                scrolledDuringTrim = prepared.navigated
            }
        }
        if visitingDocumentEnd {
            editor.scrollRangeToVisible(NSRange(location: source.utf16.count, length: 0))
            try await settleTypingProbe(nanoseconds: 500_000_000, cancelling: trimmer)
        }
        if !scrolledDuringTrim {
            editor.textSelection = NSRange(location: middle.location, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        try await settleTypingProbe(nanoseconds: 1_000_000_000, cancelling: trimmer)
        if hideGutterDraw {
            // EditorScrollView tiles the attached gutter by thickness, even when hidden.
            // This removes drawing while preserving the same text-container width.
            editor.lineNumberGutter?.isHidden = true
        }

        if environment["PLAINSONG_SCROLL_PROBE_RESCROLL_AFTER_SETTLE"] == "1" {
            editor.scrollRangeToVisible(editor.selectedRange())
            try await settleTypingProbe(nanoseconds: 1_000_000_000, cancelling: trimmer)
        }
        let preparationRequests = paragraphSpy?.report() ?? [:]
        let geometryBefore = TypingProbeGeometry(editor)
        var geometries = [geometryBefore]
        var insertMilliseconds: [Double] = []
        var paragraphRequests: [[String: Any]] = []
        var completedKeys = 0
        var recoveryMilliseconds: Double = 0
        let countersBefore = EditorProbeCounters(editor)
        let monitor = MainRunLoopBusyMonitor()
        // Lets an external `sample` attach to the measured phase only (stdout is buffered).
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("main-thread-probe-begin")
        try Data().write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        trimmerEvents?.record("typing-start", range: nil)
        monitor.start()
        // Bursts below the 150 ms preview debounce, then pauses that let every render run.
        for (count, interval) in [(30, 90), (20, 250)] {
            for _ in 0 ..< count {
                paragraphSpy?.reset(viewport: MarkdownTextView.visibleTextRange(of: editor))
                let started = DispatchTime.now().uptimeNanoseconds
                editor.insertText("a", replacementRange: editor.selectedRange())
                insertMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                let insertionRequests = paragraphSpy?.report() ?? [:]
                completedKeys += 1
                if completedKeys == Int(environment["PLAINSONG_SCROLL_PROBE_RECOVER_AFTER_KEY"] ?? "") {
                    let length = MarkdownTextView.textStorage(of: editor)?.length ?? 0
                    let tail = min(length, editor.selectedRange().location + 8192)
                    let started = DispatchTime.now().uptimeNanoseconds
                    XCTAssertTrue(EditorTextElementCacheTrimmer.trim(
                        NSRange(location: tail, length: length - tail),
                        in: editor
                    ))
                    recoveryMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    trimmerEvents?.record(
                        "diagnostic-tail-recovery",
                        range: NSRange(location: tail, length: length - tail)
                    )
                }
                trimmer?.cancel()
                if trimChunks != nil || hideGutterDraw || requestedWidth != nil {
                    geometries.append(TypingProbeGeometry(editor))
                }
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                if trimChunks != nil || hideGutterDraw || requestedWidth != nil {
                    geometries.append(TypingProbeGeometry(editor))
                }
                if let paragraphSpy {
                    paragraphRequests.append(["insert": insertionRequests, "throughRunLoop": paragraphSpy.report()])
                }
            }
        }
        try await settleTypingProbe(nanoseconds: 1_000_000_000, cancelling: trimmer)
        let slices = monitor.stop()
        trimmerEvents?.record("typing-end", range: nil)

        // Check the naturally displayed result after settling, with no forced layout:
        // a faster but blank gutter is not a successful typing result.
        if lineNumbers, !hideGutterDraw, !hideGutterEarly {
            let gutter = try XCTUnwrap(editor.lineNumberGutter)
            XCTAssertGreaterThan(gutter.drawCount, countersBefore.gutterDraws,
                                 "Typing must naturally redraw the gutter after preparation")
            let caretLine = editor.lineIndexCache.currentIndex().oneBasedLine(
                containingUTF16Offset: editor.selectedRange().location
            )
            XCTAssertFalse(gutter.lastDrawnLabels.isEmpty, "Typing must leave displayed line numbers")
            XCTAssertTrue(gutter.lastDrawnLabels.contains { $0.number == caretLine && $0.isCurrent },
                          "The naturally displayed gutter must mark the caret line")
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, hosted.appState.currentDocument.text)
        let name = visitingDocumentEnd ? "after viewing the end" : "from the middle"
        let mode = layoutMode == .sourcePreview ? "Source+preview" : "Source-only"
        var report = busySliceReport(slices)
        report.merge(EditorProbeCounters(editor).report(since: countersBefore)) { $1 }
        let diagnostics: [String: Any] = [
            "lineNumbers": lineNumbers,
            "hiddenGutterDraw": hideGutterDraw,
            "hiddenGutterEarly": hideGutterEarly,
            "recoveryMilliseconds": recoveryMilliseconds,
            "controlledTrimChunks": trimChunks ?? -1,
            "useProductionTrim": environment["PLAINSONG_SCROLL_PROBE_USE_PRODUCTION_TRIM"] == "1",
            "useAdmission": useAdmission,
            "trimYieldMilliseconds": trimYieldMilliseconds,
            "trimScrollAfter": trimScrollAfter,
            "drawAfterTrim": Int(environment["PLAINSONG_SCROLL_PROBE_DRAW_AFTER_TRIM"] ?? "") ?? -1,
            "layoutBetweenTrims": environment["PLAINSONG_SCROLL_PROBE_TRIM_LAYOUT"] == "1",
            "requestedWindowWidth": windowWidth,
            "explicitTrimRanges": explicitTrimRanges,
            "explicitTrimmedCharacters": explicitTrimRanges.reduce(0) { $0 + ($1["length"] ?? 0) },
            "insertMilliseconds": insertMilliseconds,
            "paragraphPreparation": preparationRequests,
            "trimmerEvents": trimmerEvents?.events ?? [],
            "paragraphRequests": paragraphRequests,
            "geometryBeforeTyping": geometryBefore.report,
            "geometryAfterTyping": TypingProbeGeometry(editor).report,
            "geometrySamples": geometries.map(\.report),
            "displayedLineNumbers": editor.lineNumberGutter?.lastDrawnLabels.map(\.number) ?? [],
            "displayedCurrentLines": editor.lineNumberGutter?.lastDrawnLabels.filter(\.isCurrent).map(\.number) ?? [],
            "geometryMinimum": TypingProbeGeometry.extrema(geometries, minimum: true),
            "geometryMaximum": TypingProbeGeometry.extrema(geometries, minimum: false),
        ]
        report.merge(diagnostics) { $1 }
        let reportFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typing-probe-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: reportFile)
        print("TypingProbeReportFile: \(reportFile.path)")
        recordScrollReport("\(mode) typing \(name) main-thread busy slices", report)
    }

    /// A controlled run cancels every 100 ms so a later viewport notification cannot
    /// restart the production trimmer while the explicitly selected state settles.
    private func settleTypingProbe(
        nanoseconds: UInt64,
        cancelling trimmer: EditorTextElementCacheTrimmer?
    ) async throws {
        try await TypingProbePreparation.settle(nanoseconds: nanoseconds, cancelling: trimmer)
    }

    private func busySliceReport(_ slices: [MainRunLoopBusyMonitor.Slice]) -> [String: Any] {
        let sorted = slices.map(\.wallMilliseconds).sorted()
        let longest = slices.sorted { $0.wallMilliseconds < $1.wallMilliseconds }.suffix(12)
        return [
            "slices": slices.count,
            "maxMilliseconds": sorted.last ?? 0,
            "p95Milliseconds": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
            "over16": sorted.filter { $0 > 16 }.count,
            "over50": sorted.filter { $0 > 50 }.count,
            "totalBusyMilliseconds": sorted.reduce(0, +),
            "totalCPUMilliseconds": slices.map(\.cpuMilliseconds).reduce(0, +),
            "longest": longest.map(\.wallMilliseconds),
            "longestCPU": longest.map(\.cpuMilliseconds),
            "longestStart": longest.map(\.startMilliseconds),
        ]
    }

    private func waitForLargePreview(_ hosted: HostedReplaceWorkspace) async throws {
        try await waitUntil("preview mounts", timeout: 20) {
            hosted.group.members.first?.host.previewLifecycle.controllerForShutdown?.isReady == true
        }
        let preview = try XCTUnwrap(hosted.group.members.first?.host.previewLifecycle.controllerForShutdown)
        try await waitUntil("initial large preview render", timeout: 60) {
            let count = try? await preview.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-line]').length"
            ) as? Int
            return (count ?? 0) > 10000
        }
    }

    /// `TEST_RUNNER_PLAINSONG_SCROLL_PROBE_LINE_NUMBERS=0` measures the same workload with
    /// line numbers hidden from the start (the app shows them by default).
    var scrollProbeShowsLineNumbers: Bool {
        ProcessInfo.processInfo.environment["PLAINSONG_SCROLL_PROBE_LINE_NUMBERS"] != "0"
    }
}

/// Every stretch between the main run loop waking and going back to sleep, with the
/// main thread's CPU time in it: wall time well above CPU time means the thread waited
/// (locks, synchronous IPC) rather than computed.
@MainActor
final class MainRunLoopBusyMonitor {
    struct Slice {
        /// Since `start()`, to place long slices against the typing script.
        let startMilliseconds: Double
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
    }

    private var observer: CFRunLoopObserver?
    private var wokeAt: UInt64?
    private var cpuAtWake: Double = 0
    private var startedAt: UInt64 = 0
    private var slices: [Slice] = []

    func start() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.record(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        startedAt = DispatchTime.now().uptimeNanoseconds
        wokeAt = startedAt
        cpuAtWake = Self.threadCPUMilliseconds()
    }

    func stop() -> [Slice] {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
        return slices
    }

    private func record(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        if activity == .afterWaiting {
            wokeAt = now
            cpuAtWake = Self.threadCPUMilliseconds()
        } else if let wokeAt {
            slices.append(Slice(
                startMilliseconds: Double(wokeAt - startedAt) / 1_000_000,
                wallMilliseconds: Double(now - wokeAt) / 1_000_000,
                cpuMilliseconds: Self.threadCPUMilliseconds() - cpuAtWake
            ))
            self.wokeAt = nil
        }
    }

    private static func threadCPUMilliseconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
        let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
        return user + system
    }
}
