import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// E9: export work never enters the editor keystroke path, and the existing < 16 ms typing
/// budget holds while an export is active (`docs/export-gates.md`).
///
/// One process interleaves rounds of typing with no export and typing while Export as HTML…
/// or Export as PDF… of the same 1 MiB document runs, so machine load reaches both arms alike.
/// Each keystroke records the existing §12 measure (native insertion plus the scheduled
/// public-view update) and how late it started against a fixed schedule, which is where
/// main-actor export work queued between keystrokes would show. The first keystroke fences
/// the export (E1), so typing continues until the operation finishes: the samples cover the
/// rest of the step it was in, its stop, and its teardown.
@MainActor
extension AppBackedEditorPerformanceTests {
    static let exportTypingCadence = Duration.milliseconds(80)
    static let exportTypingBaselineKeystrokes = 30
    static let exportTypingTailKeystrokes = 3
    /// Where the first keystroke lands, as a fraction of an unfenced export of the same
    /// product, rotating by round so the keystrokes reach each step of the export.
    static let exportTypingOffsetFractions = [0.05, 0.25, 0.45, 0.65]

    final class ExportTypingResultBox {
        var result: ExportHTMLOperationResult?
    }

    struct ExportTypingOperation {
        let task: Task<Void, Never>
        let operationID: UInt64
        let box: ExportTypingResultBox
    }

    struct ExportTypingProbeError: Error {
        let message: String
    }

    static var exportTypingConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    func testTypingStaysIsolatedFromActiveHTMLAndPDFExport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLAINSONG_RUN_EXPORT_E9_TYPING"] == "1" else {
            throw XCTSkip("recorded-load opt-in probe: Scripts/run-export-html-e9.sh --typing Debug|Release")
        }
        let isSmoke = environment["PLAINSONG_EXPORT_E9_SMOKE"] == "1"
        let roundCount = isSmoke ? 2 : max(4, Int(environment["PLAINSONG_E9_TYPING_ROUNDS"] ?? "") ?? 12)
        let app = try await makeAppFixture(
            source: Self.fixtureText("Fixtures/large-1mb.md"),
            directoryPrefix: "ExportTypingIsolationE9",
            fileName: "large.md"
        )
        defer { tearDownAppFixture(app) }
        app.appState.exportHTMLOperations.panelWindowProvider = { [window = app.editor.window] in window }
        XCTAssertTrue(app.editor.window.makeFirstResponder(app.editor.textView))
        app.editor.textView.textSelection = NSRange(location: 0, length: 0)
        try await pauseBetweenExportTypingArms(in: app)

        for product in [ExportCommandProduct.html, .pdf] {
            let unfenced = try await runUnfencedExport(product, in: app)
            var rounds: [ExportTypingRound] = []
            for index in 0 ..< roundCount {
                let fractions = Self.exportTypingOffsetFractions
                try await rounds.append(runExportTypingRound(
                    index: index,
                    product: product,
                    offsetMilliseconds: unfenced * fractions[index % fractions.count],
                    in: app
                ))
            }
            let summary = ExportTypingSummary(
                product: product.pathExtension,
                configuration: Self.exportTypingConfiguration,
                unfencedExportMilliseconds: unfenced,
                rounds: rounds
            )
            try reportExportTypingIsolation(summary, rounds: rounds, isSmoke: isSmoke)
        }
    }

    /// Warms WebKit and measures one export of the product with no typing; its duration sets
    /// where the export arm's first keystroke lands.
    func runUnfencedExport(_ product: ExportCommandProduct, in app: AppFixture) async throws -> Double {
        let destination = app.rootURL.appendingPathComponent("unfenced.\(product.pathExtension)")
        let start = ContinuousClock.now
        let operation = try await startExportTypingOperation(product, to: destination, in: app)
        await operation.task.value
        let elapsed = Self.exportTypingMilliseconds(ContinuousClock.now - start)
        guard case .exported = operation.box.result else {
            let result = String(describing: operation.box.result)
            throw ExportTypingProbeError(message: "unfenced \(product) export ended \(result)")
        }
        try FileManager.default.removeItem(at: destination)
        try await pauseBetweenExportTypingArms(in: app)
        return elapsed
    }

    func runExportTypingRound(
        index: Int,
        product: ExportCommandProduct,
        offsetMilliseconds: Double,
        in app: AppFixture
    ) async throws -> ExportTypingRound {
        let exportFirst = !index.isMultiple(of: 2)
        let loadBefore = Self.oneMinuteLoad()
        var withoutExport: [ExportTypingSample] = []
        var duringExport: (samples: [ExportTypingSample], result: String) = ([], "")
        if exportFirst {
            duringExport = try await typeDuringExport(product, index: index, offset: offsetMilliseconds, in: app)
            try await pauseBetweenExportTypingArms(in: app)
            withoutExport = try await typeWithoutExport(in: app)
        } else {
            withoutExport = try await typeWithoutExport(in: app)
            try await pauseBetweenExportTypingArms(in: app)
            duringExport = try await typeDuringExport(product, index: index, offset: offsetMilliseconds, in: app)
        }
        try await pauseBetweenExportTypingArms(in: app)
        return ExportTypingRound(
            index: index,
            exportFirst: exportFirst,
            offsetMilliseconds: offsetMilliseconds,
            withoutExport: withoutExport,
            duringExport: duringExport.samples,
            exportResult: duringExport.result,
            loadBefore: loadBefore,
            loadAfter: Self.oneMinuteLoad()
        )
    }

    func typeWithoutExport(in app: AppFixture) async throws -> [ExportTypingSample] {
        let start = ContinuousClock.now
        var samples: [ExportTypingSample] = []
        for keystroke in 0 ..< Self.exportTypingBaselineKeystrokes {
            let scheduled = start + Self.exportTypingCadence * keystroke
            try await Task.sleep(until: scheduled, tolerance: .zero, clock: .continuous)
            await samples.append(timeExportTypingKeystroke(in: app, scheduled: scheduled, exportOperationID: nil))
        }
        return samples
    }

    /// Types from `offset` after the export starts until three keystrokes after it finishes.
    func typeDuringExport(
        _ product: ExportCommandProduct,
        index: Int,
        offset: Double,
        in app: AppFixture
    ) async throws -> (samples: [ExportTypingSample], result: String) {
        let destination = app.rootURL.appendingPathComponent("round-\(index).\(product.pathExtension)")
        let start = ContinuousClock.now
        let operation = try await startExportTypingOperation(product, to: destination, in: app)
        let first = start + .milliseconds(offset)
        var samples: [ExportTypingSample] = []
        var keystrokesAfterFinish = 0
        var keystroke = 0
        while keystrokesAfterFinish < Self.exportTypingTailKeystrokes {
            let scheduled = first + Self.exportTypingCadence * keystroke
            keystroke += 1
            try await Task.sleep(until: scheduled, tolerance: .zero, clock: .continuous)
            let active = app.appState.exportHTMLOperations.activeOperationID == operation.operationID
            if !active { keystrokesAfterFinish += 1 }
            await samples.append(timeExportTypingKeystroke(
                in: app,
                scheduled: scheduled,
                exportOperationID: active ? operation.operationID : nil
            ))
            guard ContinuousClock.now - start < .seconds(180) else {
                throw ExportTypingProbeError(message: "\(product) export round \(index) did not finish in 180 s")
            }
        }
        await operation.task.value
        if samples.first?.exportActive == true {
            XCTAssertEqual(operation.box.result, .stopped(.documentChanged), "A keystroke fences the \(product) export")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "The fenced \(product) export writes nothing"
            )
        }
        try? FileManager.default.removeItem(at: destination)
        return (samples, String(describing: operation.box.result))
    }

    /// One keystroke: the existing hosted measure, plus whether the synchronous insertion left
    /// the export's operation and task as they were.
    func timeExportTypingKeystroke(
        in app: AppFixture,
        scheduled: ContinuousClock.Instant,
        exportOperationID: UInt64?
    ) async -> ExportTypingSample {
        let began = ContinuousClock.now
        let cpuBefore = Self.mainThreadCPUMilliseconds()
        var untouched = true
        let handler = await measureHostedUpdate(in: app.editor) {
            app.editor.textView.insertText("a", replacementRange: .notFound)
            // Read in both arms so the timed work is the same; only the export arm can differ.
            let operationID = app.appState.exportHTMLOperations.activeOperationID
            let cancelled = app.appState.exportHTMLOperations.activeTask?.isCancelled == true
            untouched = operationID == exportOperationID && !cancelled
        }
        let cpu = Self.mainThreadCPUMilliseconds() - cpuBefore
        cancelScheduledAppWork(in: app.appState)
        return ExportTypingSample(
            handlerMilliseconds: handler,
            handlerCPUMilliseconds: cpu,
            startDelayMilliseconds: Self.exportTypingMilliseconds(began - scheduled),
            exportActive: exportOperationID != nil,
            exportUntouched: untouched
        )
    }

    func startExportTypingOperation(
        _ product: ExportCommandProduct,
        to destination: URL,
        in app: AppFixture
    ) async throws -> ExportTypingOperation {
        let box = ExportTypingResultBox()
        app.appState.exportHTMLOperations.destinationChooser = { _ in destination }
        app.appState.exportHTMLOperations.didFinishOperation = { _, result in box.result = result }
        // A snapshot is refused while editor input is still synchronizing; settle and retry.
        for _ in 0 ..< 50 {
            if let task = app.appState.beginExport(product),
               let operationID = app.appState.exportHTMLOperations.activeOperationID
            {
                return ExportTypingOperation(task: task, operationID: operationID, box: box)
            }
            try await Task.sleep(for: .milliseconds(20))
            await settleScheduledSwiftUIUpdate(in: app.editor)
        }
        throw ExportTypingProbeError(message: "\(product) export could not capture a snapshot")
    }

    func pauseBetweenExportTypingArms(in app: AppFixture) async throws {
        try await Task.sleep(for: .milliseconds(500))
        await settleScheduledSwiftUIUpdate(in: app.editor)
        cancelScheduledAppWork(in: app.appState)
    }

    func reportExportTypingIsolation(
        _ summary: ExportTypingSummary,
        rounds: [ExportTypingRound],
        isSmoke: Bool
    ) throws {
        print(summary.line)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let report = try encoder.encode(ExportTypingReport(summary: summary, rounds: rounds))
        print("E9 TYPING JSON " + String(decoding: report, as: UTF8.self))
        let product = summary.product
        XCTAssertEqual(summary.untouchedViolations, 0, "A keystroke changed the \(product) export's state")
        XCTAssertGreaterThan(summary.duringExport.count, 0, "No keystroke landed while the \(product) export ran")
        if isSmoke {
            print("E9 TYPING SMOKE \(summary.product): correctness only, no timing evidence")
            return
        }
        #if DEBUG
            print("E9 TYPING \(summary.product) Debug: G1/G2 informational; the gate is Release")
        #else
            XCTAssertTrue(summary.isolationPasses, "G1 failed for \(summary.product): \(summary.medianDifference)")
            XCTAssertTrue(summary.budgetPasses, "G2 failed for \(summary.product): \(summary.duringExport)")
        #endif
    }

    static func exportTypingMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    /// The calling thread's CPU time; the probe only calls it on the main actor.
    static func mainThreadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }

    static func oneMinuteLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[0] : -1
    }
}
