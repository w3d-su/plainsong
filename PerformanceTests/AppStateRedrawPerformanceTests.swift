import AppKit
import Combine
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
final class AppStateRedrawPerformanceTests: XCTestCase {
    func testWorkspaceWindowTypingInvalidation() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLAINSONG_MEASURE_APPSTATE_REDRAW"] == "1",
            "Set TEST_RUNNER_PLAINSONG_MEASURE_APPSTATE_REDRAW=1 to measure window invalidation."
        )
        for size in [1000, 10000, 100_000] {
            for windowCount in [1, 3] {
                for _ in 0 ..< 2 {
                    try await measure(size: size, windowCount: windowCount)
                }
            }
        }
    }

    private func measure(size: Int, windowCount: Int) async throws {
        let paragraph = "## Notes\n\nA paragraph with **bold**, `inline code`, and a [link](./post.md).\n\n"
        let source = String(String(repeating: paragraph, count: size / paragraph.count + 1).prefix(size))
        let app = try EditorFindPerformanceSupport.makeAppHarness(fixtureText: source, opensFind: false)
        var facades = [app.appState]
        for _ in 1 ..< windowCount {
            let sibling = app.appState.makeSiblingFacade(admitsFileOperations: true)
            sibling.setCurrentDocument(DocumentSession(
                text: source,
                url: URL(fileURLWithPath: "/tmp/plainsong-redraw-\(UUID().uuidString).md"),
                fileKind: .markdown
            ))
            facades.append(sibling)
        }
        let windows = facades.enumerated().map { index, facade in
            makeWindow(for: facade, index: index)
        }
        defer {
            app.cancelScheduledAppWork()
            for window in windows {
                window.contentViewController = nil
                window.close()
            }
            app.cleanUp()
        }
        var editors: [MarkdownSTTextView] = []
        for window in windows {
            let view = try XCTUnwrap(window.contentViewController?.view)
            try await editors.append(EditorFindPerformanceSupport.waitForTextView(in: view))
        }
        let editor = editors[0]
        windows[0].makeKeyAndOrderFront(nil)
        XCTAssertTrue(windows[0].makeFirstResponder(editor))
        try await Task.sleep(for: .milliseconds(600))

        try await recordTyping(size: size, facades: facades, editor: editor)
    }

    private func recordTyping(size: Int, facades: [AppState], editor: MarkdownSTTextView) async throws {
        let session = facades[0].shownSession
        XCTAssertFalse(session.isDirty)
        var sessionPublishes = 0
        var facadePublishes = Array(repeating: 0, count: facades.count)
        let sessionSubscription = session.objectWillChange.sink { sessionPublishes += 1 }
        let facadeSubscriptions = facades.enumerated().map { index, facade in
            facade.objectWillChange.sink { facadePublishes[index] += 1 }
        }
        defer {
            sessionSubscription.cancel()
            facadeSubscriptions.forEach { $0.cancel() }
        }

        func sampleKey() async throws -> String {
            let version = session.version
            let sessionBefore = sessionPublishes
            let facadeBefore = facadePublishes
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let insertStart = DispatchTime.now().uptimeNanoseconds
            editor.insertText("a", replacementRange: NSRange(location: 14, length: 0))
            let insertEnd = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(for: .milliseconds(30))
            let cpuEnd = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            XCTAssertEqual(session.version, version + 1)
            let publications = zip(facadePublishes, facadeBefore).map(-)
            return "session=\(sessionPublishes - sessionBefore) facade=\(publications) "
                + String(format: "insert_ms=%.4f cpu_ms=%.4f", Double(insertEnd - insertStart) / 1e6,
                         Double(cpuEnd - cpuStart) / 1e6)
        }

        let label = "size=\(size) windows=\(facades.count)"
        try await print("REDRAW \(label) first \(sampleKey())")
        var samples: [String] = []
        for _ in 0 ..< 48 {
            try await samples.append(sampleKey())
        }
        // Capture the publication after the typing pause separately from the burst.
        let sessionBefore = sessionPublishes
        let facadeBefore = facadePublishes
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0 ..< 75 where session.availableStatistics?.characterCount != size + 49 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.availableStatistics?.characterCount, size + 49)
        XCTAssertTrue(session.isDirty)
        for sample in samples {
            print("REDRAW \(label) steady \(sample)")
        }
        let publications = zip(facadePublishes, facadeBefore).map(-)
        print("REDRAW \(label) pause session=\(sessionPublishes - sessionBefore) facade=\(publications)")
    }

    private func makeWindow(for facade: AppState, index: Int) -> NSWindow {
        let root = WorkspaceWindow(inspectorIntentOverride: .constant(false)).environmentObject(facade)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1000, height: 650))
        window.setFrameOrigin(NSPoint(x: 30 + 55 * index, y: 80 + 35 * index))
        window.orderFront(nil)
        return window
    }
}
