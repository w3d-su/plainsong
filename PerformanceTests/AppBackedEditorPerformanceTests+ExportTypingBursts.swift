import AppKit
import Darwin
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// The typing bursts and keystroke timing of the E9 typing-isolation probe.
@MainActor
extension AppBackedEditorPerformanceTests {
    struct ExportTypingArm {
        let samples: [ExportTypingSample]
        let finishedMilliseconds: Double?
        let result: String
        let fenceChecked: Bool
        let fenceHeld: Bool
    }

    /// Waits `offset` with the editor idle, as the export arm does while its export starts,
    /// then types on `schedule`. The first keystroke after a long idle is slower, so the two
    /// bursts must start after the same idle time.
    func typeWithoutExport(
        offset: Double,
        schedule: [Double],
        in app: AppFixture
    ) async throws -> [ExportTypingSample] {
        let start = ContinuousClock.now
        var samples: [ExportTypingSample] = []
        for position in 0 ..< Self.exportTypingBaselineKeystrokes {
            let scheduled = start + .milliseconds(offset + schedule[position])
            try await Task.sleep(until: scheduled, tolerance: .zero, clock: .continuous)
            await samples.append(timeExportTypingKeystroke(
                in: app, position: position, scheduled: scheduled, armStart: start, exportOperationID: nil
            ))
        }
        return samples
    }

    /// Starts the export, waits `offset`, then types on `schedule` until three keystrokes
    /// are due after the export finished.
    func typeDuringExport(
        _ product: ExportCommandProduct,
        index: Int,
        offset: Double,
        schedule: [Double],
        in app: AppFixture
    ) async throws -> ExportTypingArm {
        let destination = app.rootURL.appendingPathComponent("round-\(index).\(product.pathExtension)")
        let start = ContinuousClock.now
        let operation = try await startExportTypingOperation(product, to: destination, in: app)
        var samples: [ExportTypingSample] = []
        var dueAfterFinish = 0
        while dueAfterFinish < Self.exportTypingTailKeystrokes {
            let position = samples.count
            guard position < schedule.count else {
                throw ExportTypingProbeError(message: "\(product) export round \(index) outlasted the schedule")
            }
            let scheduled = start + .milliseconds(offset + schedule[position])
            try await Task.sleep(until: scheduled, tolerance: .zero, clock: .continuous)
            let active = app.appState.exportHTMLOperations.activeOperationID == operation.operationID
            await samples.append(timeExportTypingKeystroke(
                in: app,
                position: position,
                scheduled: scheduled,
                armStart: start,
                exportOperationID: active ? operation.operationID : nil
            ))
            if let finishedAt = operation.box.finishedAt, finishedAt <= scheduled {
                dueAfterFinish += 1
            }
        }
        await operation.task.value
        let finished = operation.box.finishedAt.map { Self.exportTypingMilliseconds($0 - start) }
        if let finished {
            for index in samples.indices {
                samples[index].duringExport = samples[index].scheduledMilliseconds < finished
            }
        }
        // Only a first keystroke that ran while the export was active proves the fence.
        let fenceChecked = samples.first?.exportActiveAtStart == true
        let wroteFile = FileManager.default.fileExists(atPath: destination.path)
        let fenceHeld = operation.box.result == .stopped(.documentChanged) && !wroteFile
        if fenceChecked {
            XCTAssertTrue(
                fenceHeld,
                "A keystroke fences the \(product) export: \(String(describing: operation.box.result))"
            )
        }
        try? FileManager.default.removeItem(at: destination)
        return ExportTypingArm(
            samples: samples,
            finishedMilliseconds: finished,
            result: operation.box.result.map { String(describing: $0) } ?? "none",
            fenceChecked: fenceChecked,
            fenceHeld: fenceHeld
        )
    }

    /// One keystroke: the existing hosted measure, its main-thread CPU, its start delay, and
    /// whether the synchronous insertion left the export's operation and task as they were.
    func timeExportTypingKeystroke(
        in app: AppFixture,
        position: Int,
        scheduled: ContinuousClock.Instant,
        armStart: ContinuousClock.Instant,
        exportOperationID: UInt64?
    ) async -> ExportTypingSample {
        let began = ContinuousClock.now
        let cpuBefore = ExportTypingBusyMonitor.threadCPUMilliseconds()
        var untouched = true
        let handler = await measureHostedUpdate(in: app.editor) {
            app.editor.textView.insertText("a", replacementRange: .notFound)
            // Read in both arms so the timed work is the same; only the export arm can differ.
            let operationID = app.appState.exportHTMLOperations.activeOperationID
            let cancelled = app.appState.exportHTMLOperations.activeTask?.isCancelled == true
            untouched = operationID == exportOperationID && !cancelled
        }
        let cpu = ExportTypingBusyMonitor.threadCPUMilliseconds() - cpuBefore
        cancelScheduledAppWork(in: app.appState)
        return ExportTypingSample(
            position: position,
            scheduledMilliseconds: Self.exportTypingMilliseconds(scheduled - armStart),
            handlerMilliseconds: handler,
            handlerCPUMilliseconds: cpu,
            startDelayMilliseconds: Self.exportTypingMilliseconds(began - scheduled),
            exportActiveAtStart: exportOperationID != nil,
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
        app.appState.exportHTMLOperations.didFinishOperation = { _, result in
            box.result = result
            box.finishedAt = .now
        }
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

    /// Prints the summary and raw report; returns the failures the caller asserts at the end.
    func reportExportTypingIsolation(
        _ summary: ExportTypingSummary,
        rounds: [ExportTypingRound],
        windows: [ExportBusyWindow],
        isSmoke: Bool
    ) throws -> [String] {
        summary.lines.forEach { print($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let report = try encoder.encode(ExportTypingReport(summary: summary, rounds: rounds, windows: windows))
        print("E9 TYPING JSON " + String(decoding: report, as: UTF8.self))
        let product = summary.product
        var failures: [String] = []
        if summary.untouchedViolations > 0 { failures.append("A keystroke changed the \(product) export's state") }
        if summary.fenceFailures > 0 { failures.append("A fenced \(product) export did not stop or wrote a file") }
        if summary.roundsWithDuringSamples == 0 { failures.append("No keystroke fell during the \(product) export") }
        if isSmoke {
            print("E9 TYPING SMOKE \(product): correctness only, no timing evidence")
            return failures
        }
        #if DEBUG
            print("E9 TYPING \(product) Debug: G0-G2 informational; the gate is Release")
        #else
            if !summary.coveragePasses { failures.append("G0 failed for \(product)") }
            if !summary.isolationPasses { failures.append("G1 failed for \(product): \(summary.comparisons)") }
            if !summary.budgetPasses { failures.append("G2 failed for \(product)") }
        #endif
        return failures
    }

    static func exportTypingMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    static func oneMinuteLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[0] : -1
    }
}
