import AppKit
import XCTest

/// Hides the windows a test fixture orders in once the test that made them finishes.
///
/// A shown window stays on screen and in `NSApplication.shared.windows` after the
/// fixture's local reference goes away. The WYSIWYG fixtures left 75 of them by the time
/// `WYSIWYGViewportPerformanceGateTests` ran, and a Core Animation run-loop timer whose
/// cost grows with the number of on-screen windows then held the main thread for ~77 ms
/// inside that gate's first sample
/// (`docs/perf/2026-11-13-wysiwyg-viewport-gate-leftover-windows.md`).
@MainActor
enum TestWindowTeardown {
    private static var windows: [NSWindow] = []
    private static let observer = Observer()
    private static var isObserving = false

    /// Keeps `window` until the running test finishes, then orders it out and releases it.
    static func hideAfterCurrentTest(_ window: NSWindow) {
        // A programmatic NSWindow defaults to release-on-close, which over-releases under
        // ARC if a test closes the window itself.
        window.isReleasedWhenClosed = false
        windows.append(window)
        if !isObserving {
            isObserving = true
            XCTestObservationCenter.shared.addTestObserver(observer)
        }
    }

    private static func hideWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    /// XCTest calls observers on the main thread, after the test's own `tearDown()`.
    private final class Observer: NSObject, XCTestObservation {
        func testCaseDidFinish(_: XCTestCase) {
            MainActor.assumeIsolated {
                TestWindowTeardown.hideWindows()
            }
        }
    }
}
