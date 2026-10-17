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
        try requireScrollProbe()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let hosted = try await makeHostedEditorWorkspace(source: source, layoutMode: .sourcePreview)
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
        let editor = try hostedEditor(hosted)
        let middle = (source as NSString).lineRange(for: NSRange(location: source.utf16.count / 2, length: 0))
        editor.textSelection = NSRange(location: middle.location, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange())
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let monitor = MainRunLoopBusyMonitor()
        // Lets an external `sample` attach to the measured phase only (stdout is buffered).
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("main-thread-probe-begin")
        try Data().write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        monitor.start()
        // Bursts below the 150 ms preview debounce, then pauses that let every render run.
        for (count, interval) in [(30, 90), (20, 250)] {
            for _ in 0 ..< count {
                editor.insertText("a", replacementRange: editor.selectedRange())
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let slices = monitor.stop()

        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, hosted.appState.currentDocument.text)
        let sorted = slices.sorted()
        recordScrollReport("Source+preview typing main-thread busy slices", [
            "slices": slices.count,
            "maxMilliseconds": sorted.last ?? 0,
            "p95Milliseconds": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
            "over16": slices.filter { $0 > 16 }.count,
            "over50": slices.filter { $0 > 50 }.count,
            "totalBusyMilliseconds": slices.reduce(0, +),
            "longest": Array(sorted.suffix(12)),
        ])
    }
}

/// Every stretch between the main run loop waking and going back to sleep.
@MainActor
final class MainRunLoopBusyMonitor {
    private var observer: CFRunLoopObserver?
    private var wokeAt: UInt64?
    private var slices: [Double] = []

    func start() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.record(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        wokeAt = DispatchTime.now().uptimeNanoseconds
    }

    func stop() -> [Double] {
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
        } else if let wokeAt {
            slices.append(Double(now - wokeAt) / 1_000_000)
            self.wokeAt = nil
        }
    }
}
