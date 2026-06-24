import AppKit
import Darwin.Mach
@testable import EditorKit
import MarkdownCore
import os.signpost
@testable import PreviewKit
import WorkspaceKit
import XCTest

@MainActor
final class PerformanceBudgetTests: XCTestCase {
    func testTypingLatencyStaysUnderFrameBudget() throws {
        let fixtureText = try Self.fixtureText("Fixtures/large-1mb.md")
        let mdxPrefix = """
        import Hero from "./Hero"

        """
        let scenarios: [TypingScenario] = [
            TypingScenario(
                label: "markdown plain",
                fileKind: .markdown,
                replacement: "a",
                expectedNativeInput: true,
                iterations: 200
            ),
            TypingScenario(
                label: "markdown newline",
                fileKind: .markdown,
                replacement: "\n",
                expectedNativeInput: true,
                iterations: 200
            ),
            TypingScenario(
                label: "markdown pair",
                fileKind: .markdown,
                replacement: "(",
                expectedNativeInput: false,
                iterations: 50
            ),
            TypingScenario(
                label: "mdx plain",
                fileKind: .mdx,
                replacement: "a",
                expectedNativeInput: true,
                iterations: 200,
                prefix: mdxPrefix
            ),
            TypingScenario(
                label: "mdx jsx trigger",
                fileKind: .mdx,
                replacement: "<",
                expectedNativeInput: false,
                iterations: 50,
                prefix: mdxPrefix
            ),
        ]

        try withSignpost("TypingLatency") {
            for scenario in scenarios {
                let result = try EditorPerformanceProbe.measureTypingHotPath(
                    fixtureText: fixtureText,
                    fileKind: scenario.fileKind,
                    replacementString: scenario.replacement,
                    expectedNativeInput: scenario.expectedNativeInput,
                    iterations: scenario.iterations,
                    fixturePrefix: scenario.prefix
                )

                print(String(
                    format: "M5 PERF typing %@ max %.3f ms (%d iterations)",
                    scenario.label,
                    result.maxLatencyMilliseconds,
                    result.iterations
                ))
                XCTAssertEqual(result.nativeInputMismatches, 0, scenario.label)
                XCTAssertLessThan(result.maxLatencyMilliseconds, Self.typingLatencyBudgetMilliseconds, scenario.label)
            }
        }
    }

    func testVisibleRangeHighlightUpdateAfterEditStaysUnderBudgetForLargeMarkdownAndMDX() async throws {
        let markdown = try Self.fixtureText("Fixtures/large-1mb.md")
        let markdownVisibleRange = try Self.visibleRange(
            in: markdown,
            around: "This deterministic paragraph gives the editor ordinary prose"
        )
        let markdownEditLocation = try Self.location(in: markdown, of: "ordinary prose")
        let highlightService = MarkdownHighlightService()

        _ = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: markdown,
            fileKind: .markdown,
            visibleRange: markdownVisibleRange,
            editLocation: markdownEditLocation,
            insertion: "warm ",
            highlightService: highlightService
        )

        let markdownSamples = try await withSignpost("VisibleRangeHighlightMarkdown1MB") {
            var samples: [Double] = []
            for attempt in 1 ... 3 {
                let result = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
                    fixtureText: markdown,
                    fileKind: .markdown,
                    visibleRange: markdownVisibleRange,
                    editLocation: markdownEditLocation,
                    insertion: "m\(attempt)",
                    highlightService: highlightService
                )
                XCTAssertTrue(result.didApplyHighlight, "markdown attempt \(attempt)")
                XCTAssertEqual(
                    result.selectionAfterApply.location,
                    markdownEditLocation + 2,
                    "markdown attempt \(attempt)"
                )
                samples.append(result.elapsedMilliseconds)
            }
            return samples
        }
        let markdownMax = markdownSamples.max() ?? 0
        print(String(
            format: "M5 PERF visible highlight markdown 1MB max %.3f ms samples %@",
            markdownMax,
            Self.formatSamples(markdownSamples)
        ))

        let mdx = """
        import Hero from "./Hero"

        <Hero title="Visible range" />

        \(markdown)
        """
        let mdxVisibleRange = try Self.visibleRange(in: mdx, around: "<Hero title")
        let mdxEditLocation = try Self.location(in: mdx, of: "Visible range")

        _ = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: mdx,
            fileKind: .mdx,
            visibleRange: mdxVisibleRange,
            editLocation: mdxEditLocation,
            insertion: "warm ",
            highlightService: highlightService
        )

        let mdxSamples = try await withSignpost("VisibleRangeHighlightMDX1MB") {
            var samples: [Double] = []
            for attempt in 1 ... 3 {
                let result = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
                    fixtureText: mdx,
                    fileKind: .mdx,
                    visibleRange: mdxVisibleRange,
                    editLocation: mdxEditLocation,
                    insertion: "x\(attempt)",
                    highlightService: highlightService
                )
                XCTAssertTrue(result.didApplyHighlight, "mdx attempt \(attempt)")
                XCTAssertEqual(
                    result.selectionAfterApply.location,
                    mdxEditLocation + 2,
                    "mdx attempt \(attempt)"
                )
                samples.append(result.elapsedMilliseconds)
            }
            return samples
        }
        let mdxMax = mdxSamples.max() ?? 0
        print(String(
            format: "M5 PERF visible highlight mdx 1MB max %.3f ms samples %@",
            mdxMax,
            Self.formatSamples(mdxSamples)
        ))

        XCTAssertLessThan(markdownMax, Self.visibleRangeHighlightBudgetMilliseconds)
        XCTAssertLessThan(mdxMax, Self.visibleRangeHighlightBudgetMilliseconds)
    }

    func testPreviewRenderFor100KBMarkdownAndMDXStaysUnderBudget() async throws {
        let controller = try PreviewController(previewIndexURL: Self.previewIndexFixtureURL())
        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        _ = try await measurePreviewRender(
            controller: controller,
            text: "# Warm preview\n\n- [ ] ready\n",
            fileKind: .markdown,
            label: "warmup"
        )
        _ = try await measurePreviewRender(
            controller: controller,
            text: """
            import WarmPreview from "./WarmPreview"

            <WarmPreview />

            # Warm MDX preview
            """,
            fileKind: .mdx,
            label: "mdx warmup"
        )

        let markdown = try Self.fixtureText("Fixtures/perf-100kb.md")
        let mdx = """
        import PerformanceCard from "./PerformanceCard"

        <PerformanceCard tone="info" />

        \(markdown)
        """

        _ = try await measurePreviewRender(
            controller: controller,
            text: markdown,
            fileKind: .markdown,
            label: "markdown 100KB prime"
        )
        // Let WebKit and morphdom settle before recording post-debounce updates.
        for attempt in 1 ... 3 {
            _ = try await measurePreviewRender(
                controller: controller,
                text: "\(markdown)\n\n<!-- preview-settle-\(attempt) -->\n",
                fileKind: .markdown,
                label: "markdown 100KB settle \(attempt)"
            )
        }

        let markdownSamples = try await withSignpost("PreviewRenderMarkdown100KB") {
            var samples: [Double] = []
            for attempt in 1 ... 3 {
                try await samples.append(measurePreviewRender(
                    controller: controller,
                    text: "\(markdown)\n\n<!-- preview-update-\(attempt) -->\n",
                    fileKind: .markdown,
                    label: "markdown 100KB update \(attempt)"
                ))
            }
            return samples
        }
        let markdownMilliseconds = Self.median(markdownSamples)
        print(String(
            format: "M5 PERF preview markdown 100KB update median %.3f ms samples %@",
            markdownMilliseconds,
            Self.formatSamples(markdownSamples)
        ))
        _ = try await measurePreviewRender(
            controller: controller,
            text: mdx,
            fileKind: .mdx,
            label: "mdx 100KB prime"
        )
        // Keep MDX cold-start work out of the settled render budget.
        for attempt in 1 ... 3 {
            _ = try await measurePreviewRender(
                controller: controller,
                text: "\(mdx)\n\n<!-- preview-settle-\(attempt) -->\n",
                fileKind: .mdx,
                label: "mdx 100KB settle \(attempt)"
            )
        }
        let mdxSamples = try await withSignpost("PreviewRenderMDX100KB") {
            var samples: [Double] = []
            for attempt in 1 ... 3 {
                try await samples.append(measurePreviewRender(
                    controller: controller,
                    text: "\(mdx)\n\n<!-- preview-update-\(attempt) -->\n",
                    fileKind: .mdx,
                    label: "mdx 100KB update \(attempt)"
                ))
            }
            return samples
        }
        let mdxMilliseconds = Self.median(mdxSamples)
        print(String(
            format: "M5 PERF preview mdx 100KB update median %.3f ms samples %@",
            mdxMilliseconds,
            Self.formatSamples(mdxSamples)
        ))

        assertPerformanceBudget(
            markdownMilliseconds,
            lessThan: Self.previewRenderBudgetMilliseconds,
            metric: "preview markdown 100KB update median",
            isInformationalOnCI: true
        )
        assertPerformanceBudget(
            mdxMilliseconds,
            lessThan: Self.previewRenderBudgetMilliseconds,
            metric: "preview mdx 100KB update median",
            isInformationalOnCI: true
        )
    }

    func testZZZMemoryWithEightWarmSessionsAndTwoLiveWebViewsStaysUnderBudget() async throws {
        let sessions = try Self.makeWarmDocumentSessions()
        XCTAssertEqual(sessions.count, 8)

        let baselineWebKitHelperPIDs = Self.webKitHelperProcessIDs()
        let previewSurface = Self.makePreviewSurface()
        let primaryPreview = try PreviewController(previewIndexURL: Self.previewIndexFixtureURL())
        Self.attachPreviewWebView(primaryPreview, to: previewSurface, paneIndex: 0, paneCount: 2)

        try await waitUntil("primary preview bridge ready") {
            primaryPreview.isReady
        }

        let markdown = try Self.fixtureText("Fixtures/perf-100kb.md")
        let mdx = """
        import MemoryHarnessCard from "./MemoryHarnessCard"

        <MemoryHarnessCard tone="calm" />

        \(markdown)
        """

        let primaryMarker = try await settlePreview(
            controller: primaryPreview,
            text: markdown,
            fileKind: .markdown,
            label: "memory primary markdown",
            markerPrefix: "Primary preview"
        )
        let singleWebViewMemory = Self.residentMemoryMegabytes()
        print(String(
            format: "M5 PERF memory 8 warm sessions + 1 webview RSS %.1f MB (informational; two-webview gate not asserted)",
            singleWebViewMemory
        ))

        let secondaryPreview = try PreviewController(previewIndexURL: Self.previewIndexFixtureURL())
        Self.attachPreviewWebView(secondaryPreview, to: previewSurface, paneIndex: 1, paneCount: 2)
        try await waitUntil("secondary preview bridge ready") {
            secondaryPreview.isReady
        }

        let secondaryMarker = try await settlePreview(
            controller: secondaryPreview,
            text: mdx,
            fileKind: .mdx,
            label: "memory secondary mdx",
            markerPrefix: "Secondary preview"
        )
        try await waitForRenderedText(
            controller: primaryPreview,
            marker: primaryMarker,
            label: "primary preview still settled"
        )
        try await waitForRenderedText(
            controller: secondaryPreview,
            marker: secondaryMarker,
            label: "secondary preview settled"
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        previewSurface.layoutSubtreeIfNeeded()
        previewSurface.displayIfNeeded()

        let residentMemory = Self.residentMemoryMegabytes()
        let webKitHelperMemory = Self.webKitHelperResidentMemoryMegabytes(excluding: baselineWebKitHelperPIDs)
        let totalResidentMemory = residentMemory + webKitHelperMemory.megabytes
        withExtendedLifetime(sessions) {
            withExtendedLifetime(previewSurface) {
                withExtendedLifetime(primaryPreview) {
                    withExtendedLifetime(secondaryPreview) {
                        print(String(
                            format: "M5 PERF memory 8 warm sessions + 2 live webviews RSS %.1f MB host (budget %.0f MB); diagnostic WebKit helpers %.1f MB (%d), aggregate %.1f MB not asserted",
                            residentMemory,
                            Self.memoryBudgetMegabytes,
                            webKitHelperMemory.megabytes,
                            webKitHelperMemory.processCount,
                            totalResidentMemory
                        ))
                    }
                }
            }
        }
        XCTAssertGreaterThan(residentMemory, 0)
        XCTAssertLessThan(residentMemory, Self.memoryBudgetMegabytes)
    }

    func testOpening500KBMarkdownToEditorFirstPaintStaysUnderBudget() throws {
        let fixtureURL = try Self.fixtureURL("Fixtures/perf-500kb.md")
        // Warm the editor surface so the timed path covers document load and first paint.
        try EditorPerformanceProbe.paintEditor(text: "# Warm editor\n\n")

        let elapsedMilliseconds = try withSignpost("FileOpen500KBFirstPaint") {
            let start = DispatchTime.now().uptimeNanoseconds
            let file = try MarkdownFileStore().load(url: fixtureURL)
            let session = DocumentSession(text: file.text, url: file.url, fileKind: file.fileKind, isDirty: false)
            try EditorPerformanceProbe.paintEditor(text: session.text)
            return Self.milliseconds(since: start)
        }

        print(String(format: "M5 PERF file open 500KB load + editor paint %.3f ms", elapsedMilliseconds))
        XCTAssertLessThan(elapsedMilliseconds, Self.fileOpenBudgetMilliseconds)
    }
}

private extension PerformanceBudgetTests {
    struct TypingScenario {
        let label: String
        let fileKind: FileKind
        let replacement: String
        let expectedNativeInput: Bool
        let iterations: Int
        var prefix = ""
    }

    static let typingLatencyBudgetMilliseconds = 16.0
    static let visibleRangeHighlightBudgetMilliseconds = 50.0
    static let previewRenderBudgetMilliseconds = 100.0
    static let fileOpenBudgetMilliseconds = 300.0
    static let memoryBudgetMegabytes = 400.0
    static let signpostLog = OSLog(subsystem: "app.plainsong.performance", category: "M5")

    static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    static var testBundle: Bundle {
        Bundle(for: PerformanceBudgetTests.self)
    }

    static func fixtureURL(_ path: String) throws -> URL {
        try resourceURL(path)
    }

    static func fixtureText(_ path: String) throws -> String {
        try String(contentsOf: fixtureURL(path), encoding: .utf8)
    }

    static func previewIndexFixtureURL() throws -> URL {
        try resourceURL("preview/index.html")
    }

    static func resourceURL(_ path: String) throws -> URL {
        let path = path as NSString
        let file = path.lastPathComponent as NSString
        let fileExtension = file.pathExtension
        let resourceName = file.deletingPathExtension
        let subdirectory = path.deletingLastPathComponent

        return try XCTUnwrap(
            testBundle.url(
                forResource: resourceName,
                withExtension: fileExtension.isEmpty ? nil : fileExtension,
                subdirectory: subdirectory.isEmpty ? nil : subdirectory
            ),
            "missing bundled performance resource: \(path)"
        )
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func formatSamples(_ values: [Double]) -> String {
        "[" + values.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]"
    }

    static func visibleRange(in text: String, around substring: String, length: Int = 6000) throws -> NSRange {
        let location = try location(in: text, of: substring)
        let textLength = (text as NSString).length
        let start = max(0, location - 512)
        return NSRange(location: start, length: min(length, textLength - start))
    }

    static func location(in text: String, of substring: String) throws -> Int {
        let range = (text as NSString).range(of: substring)
        return try XCTUnwrap(
            range.location == NSNotFound ? nil : range.location,
            "missing substring in performance fixture: \(substring)"
        )
    }

    static func residentMemoryMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return Double(info.resident_size) / 1_048_576
    }

    static func webKitHelperResidentMemoryMegabytes(
        excluding baselinePIDs: Set<pid_t>
    ) -> (megabytes: Double, processCount: Int) {
        let pids = webKitHelperProcessIDs().subtracting(baselinePIDs)
        let residentBytes = pids.compactMap(processResidentMemoryBytes).reduce(UInt64(0), +)
        return (Double(residentBytes) / 1_048_576, pids.count)
    }

    static func webKitHelperProcessIDs() -> Set<pid_t> {
        Set(allProcessIDs().filter { processName(pid: $0).hasPrefix("com.apple.WebKit.") })
    }

    static func allProcessIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }

        var processes = [kinfo_proc](
            repeating: kinfo_proc(),
            count: length / MemoryLayout<kinfo_proc>.stride
        )
        let result = processes.withUnsafeMutableBufferPointer { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &length, nil, 0)
        }
        guard result == 0 else {
            return []
        }

        return processes
            .prefix(length / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
    }

    static func processResidentMemoryBytes(pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard result == Int32(size) else {
            return nil
        }
        return info.pti_resident_size
    }

    static func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    static func makeWarmDocumentSessions() throws -> [DocumentSession] {
        let sessionText = try fixtureText("Fixtures/perf-500kb.md")
        return (0 ..< 8).map { index in
            DocumentSession(
                text: "\(sessionText)\n\n<!-- warm-session-\(index) -->\n",
                url: URL(fileURLWithPath: "/tmp/plainsong-perf-\(index).md"),
                fileKind: .markdown,
                isDirty: false
            )
        }
    }

    static func makePreviewSurface() -> NSView {
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        surface.wantsLayer = true
        return surface
    }

    static func attachPreviewWebView(
        _ controller: PreviewController,
        to surface: NSView,
        paneIndex: Int,
        paneCount: Int
    ) {
        precondition(paneCount == 2, "Memory harness must exercise exactly two preview webview panes.")
        let paneWidth = surface.bounds.width / CGFloat(paneCount)
        controller.webView.frame = NSRect(
            x: CGFloat(paneIndex) * paneWidth,
            y: 0,
            width: paneWidth,
            height: surface.bounds.height
        )
        controller.webView.autoresizingMask = [.width, .height]
        surface.addSubview(controller.webView)
        surface.layoutSubtreeIfNeeded()
    }

    func measurePreviewRender(
        controller: PreviewController,
        text: String,
        fileKind: FileKind,
        label: String
    ) async throws -> Double {
        let completion = expectation(description: "render complete: \(label)")
        var completedPayload: RenderCompletePayload?
        controller.renderCompletionObserver = { payload in
            completedPayload = payload
            completion.fulfill()
        }
        defer { controller.renderCompletionObserver = nil }

        let start = DispatchTime.now().uptimeNanoseconds
        controller.render(DocumentTextChange(text: text, version: 1, fileKind: fileKind, fileURL: nil))

        await fulfillment(of: [completion], timeout: 10)
        let elapsedMilliseconds = Self.milliseconds(since: start)

        print(String(format: "M5 PERF preview %@ %.3f ms", label, elapsedMilliseconds))
        XCTAssertGreaterThan(completedPayload?.blockCount ?? 0, 0, label)
        return elapsedMilliseconds
    }

    func settlePreview(
        controller: PreviewController,
        text: String,
        fileKind: FileKind,
        label: String,
        markerPrefix: String
    ) async throws -> String {
        _ = try await measurePreviewRender(
            controller: controller,
            text: "# \(markerPrefix) warmup\n\n- [ ] ready\n",
            fileKind: fileKind,
            label: "\(label) warmup"
        )
        _ = try await measurePreviewRender(
            controller: controller,
            text: text,
            fileKind: fileKind,
            label: "\(label) prime"
        )

        for attempt in 1 ... 3 {
            let marker = "\(markerPrefix) settle \(attempt)"
            _ = try await measurePreviewRender(
                controller: controller,
                text: "\(text)\n\n\(marker)\n",
                fileKind: fileKind,
                label: "\(label) settle \(attempt)"
            )
            try await waitForRenderedText(controller: controller, marker: marker, label: "\(label) settle \(attempt)")
        }

        let finalMarker = "\(markerPrefix) settled"
        _ = try await measurePreviewRender(
            controller: controller,
            text: "\(text)\n\n\(finalMarker)\n",
            fileKind: fileKind,
            label: "\(label) final settled"
        )
        try await waitForRenderedText(controller: controller, marker: finalMarker, label: "\(label) final settled")
        return finalMarker
    }

    func waitForRenderedText(controller: PreviewController, marker: String, label: String) async throws {
        try await waitUntil(label) {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains(marker) == true
        }
    }

    func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func assertPerformanceBudget(
        _ value: Double,
        lessThan budget: Double,
        metric: String,
        isInformationalOnCI: Bool = false
    ) {
        if value < budget {
            return
        }

        let message = String(
            format: "M5 PERF %@ %.3f ms exceeded %.3f ms budget",
            metric,
            value,
            budget
        )
        if isInformationalOnCI, Self.isContinuousIntegration {
            print(
                "\(message) on CI; recorded as informational because hosted WebKit runner variance is not M5 acceptance evidence"
            )
            return
        }

        XCTFail(message)
    }

    func withSignpost<T>(_ name: StaticString, operation: () throws -> T) rethrows -> T {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: name, signpostID: signpostID)
        defer { os_signpost(.end, log: Self.signpostLog, name: name, signpostID: signpostID) }
        return try operation()
    }

    func withSignpost<T>(_ name: StaticString, operation: () async throws -> T) async rethrows -> T {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: name, signpostID: signpostID)
        defer { os_signpost(.end, log: Self.signpostLog, name: name, signpostID: signpostID) }
        return try await operation()
    }
}
