import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// E9: export work never enters the editor keystroke path, and the existing < 16 ms typing
/// budget holds while an export is active (`docs/export-gates.md`). Method and gates:
/// `docs/perf/2026-11-18-export-e9-typing-isolation.md`.
///
/// For HTML and then PDF, on the same 1 MiB document: warm exports and idle windows of the
/// same length record every main run loop slice with no typing, which is all the main-thread
/// work an export does; then interleaved rounds pair a typing burst with no export against
/// a burst while the export runs. Both bursts use the same jittered schedule and are compared
/// at matching burst positions. A keystroke counts as during the export when it was due
/// before the export finished, so one held up by the export's last synchronous step (fence,
/// write, teardown) counts.
@MainActor
extension AppBackedEditorPerformanceTests {
    static let exportTypingCadenceMilliseconds = 80.0
    static let exportTypingBaselineKeystrokes = 30
    static let exportTypingTailKeystrokes = 3
    static let exportTypingMaximumKeystrokes = 1500
    /// Where the export burst starts, as a fraction of a warm export, by round.
    static let exportTypingOffsetFractions = [0.05, 0.3, 0.55, 0.8]

    final class ExportTypingResultBox {
        var result: ExportHTMLOperationResult?
        var finishedAt: ContinuousClock.Instant?
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
        let roundCount = isSmoke ? 2 : max(8, Int(environment["PLAINSONG_E9_TYPING_ROUNDS"] ?? "") ?? 16)
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

        // Gates are asserted after both products, and an error in one product is reported
        // without discarding the other's results.
        var failures: [String] = []
        for product in [ExportCommandProduct.html, .pdf] {
            do {
                failures += try await runExportTypingProduct(product, roundCount: roundCount, isSmoke: isSmoke, in: app)
            } catch {
                print("E9 TYPING \(product.pathExtension) aborted: \(error)")
                failures.append("\(product.pathExtension) aborted: \(error)")
            }
        }
        for failure in failures {
            XCTFail(failure)
        }
    }

    /// Busy windows, then the interleaved rounds, for one product; returns its gate failures.
    func runExportTypingProduct(
        _ product: ExportCommandProduct,
        roundCount: Int,
        isSmoke: Bool,
        in app: AppFixture
    ) async throws -> [String] {
        // The first export in the process pays one-time WebKit costs; it sets nothing.
        _ = try await recordExportBusyWindow(product, in: app)
        var windows = try await [recordExportBusyWindow(product, in: app)]
        try await windows.append(recordIdleBusyWindow(milliseconds: windows[0].durationMilliseconds, in: app))
        try await windows.append(recordIdleBusyWindow(milliseconds: windows[0].durationMilliseconds, in: app))
        try await windows.append(recordExportBusyWindow(product, in: app))
        let exportDurations = windows.filter { $0.kind == "export" }.map(\.durationMilliseconds)
        let warm = exportDurations.reduce(0, +) / Double(exportDurations.count)

        var rounds: [ExportTypingRound] = []
        let fractions = Self.exportTypingOffsetFractions
        for index in 0 ..< roundCount {
            // Alternates by round, and flips every cycle of offsets, so each offset runs in
            // both orders.
            let exportFirst = index.isMultiple(of: 2) == ((index / fractions.count) % 2 == 1)
            let round = try await runExportTypingRound(
                index: index,
                product: product,
                offsetMilliseconds: warm * fractions[index % fractions.count],
                exportFirst: exportFirst,
                in: app
            )
            rounds.append(round)
            print(String(
                format: "E9 TYPING progress %@ round %d: offset %.0f ms, %d during, load %.2f, %@",
                product.pathExtension, index, round.offsetMilliseconds, round.duringExport.count,
                round.loadAfter, round.exportResult
            ))
        }
        let summary = ExportTypingSummary(
            product: product.pathExtension,
            configuration: Self.exportTypingConfiguration,
            warmExportMilliseconds: warm,
            rounds: rounds,
            windows: windows
        )
        return try reportExportTypingIsolation(summary, rounds: rounds, windows: windows, isSmoke: isSmoke)
    }

    /// One export run to completion with no typing, recording every main run loop slice.
    func recordExportBusyWindow(_ product: ExportCommandProduct, in app: AppFixture) async throws -> ExportBusyWindow {
        let destination = app.rootURL.appendingPathComponent("unfenced.\(product.pathExtension)")
        let monitor = ExportTypingBusyMonitor()
        monitor.start()
        let start = ContinuousClock.now
        let operation = try await startExportTypingOperation(product, to: destination, in: app)
        await operation.task.value
        let duration = Self.exportTypingMilliseconds((operation.box.finishedAt ?? .now) - start)
        let slices = monitor.stop()
        guard case .exported = operation.box.result else {
            let result = String(describing: operation.box.result)
            throw ExportTypingProbeError(message: "unfenced \(product) export ended \(result)")
        }
        try FileManager.default.removeItem(at: destination)
        try await pauseBetweenExportTypingArms(in: app)
        return ExportBusyWindow(kind: "export", durationMilliseconds: duration, slices: slices)
    }

    func recordIdleBusyWindow(milliseconds: Double, in app: AppFixture) async throws -> ExportBusyWindow {
        let monitor = ExportTypingBusyMonitor()
        monitor.start()
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(milliseconds))
        let duration = Self.exportTypingMilliseconds(ContinuousClock.now - start)
        let slices = monitor.stop()
        try await pauseBetweenExportTypingArms(in: app)
        return ExportBusyWindow(kind: "idle", durationMilliseconds: duration, slices: slices)
    }

    func runExportTypingRound(
        index: Int,
        product: ExportCommandProduct,
        offsetMilliseconds: Double,
        exportFirst: Bool,
        in app: AppFixture
    ) async throws -> ExportTypingRound {
        // Both bursts share one jittered schedule: keystrokes 40-120 ms apart, so they land
        // at different phases of the export's own work from round to round.
        var generator = SplitMix64(seed: ExportTypingStatistics.bootstrapSeed &+ UInt64(index))
        let cadence = Self.exportTypingCadenceMilliseconds
        let schedule = (0 ..< Self.exportTypingMaximumKeystrokes).map {
            cadence * Double($0) + Double.random(in: 0 ..< cadence / 2, using: &generator)
        }
        let loadBefore = Self.oneMinuteLoad()
        let withoutExport: [ExportTypingSample]
        let exportArm: ExportTypingArm
        if exportFirst {
            exportArm = try await typeDuringExport(
                product,
                index: index,
                offset: offsetMilliseconds,
                schedule: schedule,
                in: app
            )
            try await pauseBetweenExportTypingArms(in: app)
            withoutExport = try await typeWithoutExport(offset: offsetMilliseconds, schedule: schedule, in: app)
        } else {
            withoutExport = try await typeWithoutExport(offset: offsetMilliseconds, schedule: schedule, in: app)
            try await pauseBetweenExportTypingArms(in: app)
            exportArm = try await typeDuringExport(
                product,
                index: index,
                offset: offsetMilliseconds,
                schedule: schedule,
                in: app
            )
        }
        try await pauseBetweenExportTypingArms(in: app)
        return ExportTypingRound(
            index: index,
            exportFirst: exportFirst,
            offsetMilliseconds: offsetMilliseconds,
            withoutExport: withoutExport,
            exportArm: exportArm.samples,
            exportFinishedMilliseconds: exportArm.finishedMilliseconds,
            exportResult: exportArm.result,
            fenceChecked: exportArm.fenceChecked,
            fenceHeld: exportArm.fenceHeld,
            loadBefore: loadBefore,
            loadAfter: Self.oneMinuteLoad()
        )
    }
}
