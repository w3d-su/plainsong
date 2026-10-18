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
        try await recordSourcePreviewTypingBusySlices(visitingDocumentEnd: false)
    }

    /// Viewing the end once leaves TextKit's element cache filled to there (see
    /// `EditorTextElementCacheTrimmer`); typing above it is the common case afterwards.
    func testHostedSourcePreviewTypingAfterViewingDocumentEndMainThreadBusySlices() async throws {
        try await recordSourcePreviewTypingBusySlices(visitingDocumentEnd: true)
    }

    private func recordSourcePreviewTypingBusySlices(visitingDocumentEnd: Bool) async throws {
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
        if visitingDocumentEnd {
            editor.scrollRangeToVisible(NSRange(location: source.utf16.count, length: 0))
            try await Task.sleep(nanoseconds: 500_000_000)
        }
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
        let sorted = slices.map(\.wallMilliseconds).sorted()
        let longest = slices.sorted { $0.wallMilliseconds < $1.wallMilliseconds }.suffix(12)
        let name = visitingDocumentEnd ? "after viewing the end" : "from the middle"
        recordScrollReport("Source+preview typing \(name) main-thread busy slices", [
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
        ])
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
