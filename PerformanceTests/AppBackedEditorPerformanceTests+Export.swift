import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
extension AppBackedEditorPerformanceTests {
    /// Native input plus the scheduled public-view update while the production export render is
    /// active. This is synthetic AppKit evidence; physical-input/compositor timing is owner-only.
    func testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget() async throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_EXPORT_E9"] == "1" else {
            throw XCTSkip("pending idle-machine run: Scripts/run-export-html-e9.sh Debug|Release")
        }
        let source = try Self.fixtureText("Fixtures/large-1mb.md")
        let app = try await makeAppFixture(source: source, directoryPrefix: "ExportTypingE9", fileName: "large.md")
        defer { tearDownAppFixture(app) }
        app.appState.exportHTMLOperations.panelWindowProvider = { [window = app.editor.window] in window }
        cancelScheduledAppWork(in: app.appState)
        let destination = app.rootURL.appendingPathComponent("typing.html")
        var release: CheckedContinuation<Void, Never>?
        app.appState.exportHTMLOperations.destinationChooser = { _ in destination }
        app.appState.exportHTMLOperations.didInspectDestination = {
            await withCheckedContinuation { release = $0 }
        }
        let export = try XCTUnwrap(app.appState.exportCurrentDocumentAsHTML())
        let deadline = Date().addingTimeInterval(20)
        while release == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let release else {
            app.appState.cancelExportHTML()
            await export.value
            return XCTFail("E9 export did not reach destination inspection")
        }
        release.resume()
        await Task.yield()
        XCTAssertNotNil(app.appState.exportHTMLOperations.activeOperationID)
        app.editor.textView.textSelection = NSRange(location: 0, length: 0)
        let latency = await measureHostedUpdate(in: app.editor) {
            app.editor.textView.insertText("a", replacementRange: .notFound)
        }
        if ProcessInfo.processInfo.environment["PLAINSONG_EXPORT_E9_SMOKE"] == "1" {
            print("EXPORT E9 SMOKE typing body executed; no budget assertion or timing evidence")
        } else {
            print("EXPORT E9 native input + public-view update during active export \(latency) ms")
            assertFrameBudget(latency, label: "typing during HTML export")
        }
        await export.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "The edit fences the snapshot write")
    }
}
