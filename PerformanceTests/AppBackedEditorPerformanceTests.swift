import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
final class AppBackedEditorPerformanceTests: XCTestCase {
    func testAuthorizedDocumentPublicationInvariantsStayWithinFrameBudgetForOneMiBSource() throws {
        let persistedSource = try Self.fixtureText("Fixtures/large-1mb.md") + "\nA"
        XCTAssertGreaterThanOrEqual(persistedSource.utf8.count, 1_048_576)

        // Build independent buffers before timing so each sample exercises literal
        // source comparison without charging fixture allocation to the hot path.
        let exactNoOpSource = String(decoding: Array(persistedSource.utf8), as: UTF8.self)
        let editedSource = String(persistedSource.dropLast()) + "B"
        let restoredSource = String(decoding: Array(persistedSource.utf8), as: UTF8.self)
        let session = DocumentSession(text: persistedSource, fileKind: .markdown)

        let exactNoOpLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(exactNoOpSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 0)
        XCTAssertFalse(session.isDirty)

        let sameLengthEditLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(editedSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)

        let persistedBaselineLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(restoredSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 2)
        XCTAssertFalse(session.isDirty)

        print(String(
            format: "WS3B PERF authorized publication 1 MiB no-op %.3f ms, tail edit %.3f ms, baseline %.3f ms",
            exactNoOpLatency,
            sameLengthEditLatency,
            persistedBaselineLatency
        ))
        assertFrameBudget(exactNoOpLatency, label: "authorized exact no-op")
        assertFrameBudget(sameLengthEditLatency, label: "authorized same-length tail edit")
        assertFrameBudget(persistedBaselineLatency, label: "authorized persisted-baseline restore")
    }

    func testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget() async throws {
        let source = try "AoldB" + (Self.fixtureText("Fixtures/large-1mb.md"))
        XCTAssertGreaterThanOrEqual(source.utf8.count, 1_048_576)
        let appFixture = try await makeAppFixture(
            source: source,
            directoryPrefix: "AppBackedEditorPerformanceTests",
            fileName: "large.md"
        )
        defer { tearDownAppFixture(appFixture) }
        let fixture = appFixture.editor

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)

        try await assertAppBackedStaleIMEBoundaryReconciliation(
            in: appFixture,
            caretLocation: 1,
            expectedPrefix: "A\u{81FA}e\u{0301}\u{1F9EA}B"
        )
        cancelScheduledAppWork(in: appFixture.appState)
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)
        appFixture.appState.editorDocumentSourceFullComparisonCounts.removeAll()
        assertNoFullSourceComparisons(in: appFixture.appState)
        fixture.textView.textSelection = NSRange(location: 0, length: 0)

        let ordinaryLatency = await measureHostedUpdate(in: fixture) {
            fixture.textView.insertText("a", replacementRange: .notFound)
        }
        let pairLatency = await measureHostedUpdate(in: fixture) {
            fixture.textView.insertText("(", replacementRange: .notFound)
        }
        let markedTextLatencies = await measureMarkedTextUpdates(in: fixture)

        // Let the public view's debounced background highlight lifecycle drain too.
        // Its MainActor request preparation is source-size-independent; this delayed
        // cycle must also avoid the instrumented App/native whole-source comparisons.
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)

        XCTAssertTrue(appFixture.session.text.hasPrefix("a()\u{8A3B}e\u{0301}"))
        XCTAssertEqual(fixture.textView.text, appFixture.session.text)
        assertNoFullSourceComparisons(in: appFixture.appState)
        print(String(
            format: "WS3B PERF hosted public 1 MiB ordinary %.3f ms, pair %.3f ms, marked max %.3f ms",
            ordinaryLatency,
            pairLatency,
            markedTextLatencies.max() ?? 0
        ))
        assertFrameBudget(ordinaryLatency, label: "ordinary insertion")
        assertFrameBudget(pairLatency, label: "re-entrant pair insertion")
        for (index, latency) in markedTextLatencies.enumerated() {
            assertFrameBudget(latency, label: "marked-text update \(index + 1)")
        }
    }

    func testHostedAppStateStaleIMEReplacementBoundariesPreserveExactUTF16() async throws {
        let scenarios: [(caretLocation: Int, expectedPrefix: String)] = [
            (1, "A\u{81FA}e\u{0301}\u{1F9EA}B"),
            (4, "A\u{1F9EA}\u{81FA}e\u{0301}B"),
        ]

        for scenario in scenarios {
            try await assertHostedAppStateStaleIMEBoundary(
                caretLocation: scenario.caretLocation,
                expectedPrefix: scenario.expectedPrefix
            )
        }
    }

    func testHostedSelectionOnlyClosingSkipLeavesAppAndDiskStateUnchanged() async throws {
        let source = "()"
        let appFixture = try await makeAppFixture(
            source: source,
            directoryPrefix: "AppBackedEditorSelectionTests",
            fileName: "selection.md"
        )
        defer { tearDownAppFixture(appFixture) }
        let fixture = appFixture.editor
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = NSRange(location: 1, length: 0)
        await settleScheduledSwiftUIUpdate(in: fixture)
        appFixture.appState.editorDocumentSourceFullComparisonCounts.removeAll()

        fixture.textView.insertText(")", replacementRange: .notFound)
        await settleScheduledSwiftUIUpdate(in: fixture)

        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(fixture.textView.text, source)
        XCTAssertEqual(appFixture.session.text, source)
        XCTAssertEqual(appFixture.session.version, 0)
        XCTAssertFalse(appFixture.session.isDirty)
        XCTAssertNil(appFixture.appState.autosaveTask)
        XCTAssertEqual(try String(contentsOf: appFixture.documentURL, encoding: .utf8), source)
        assertNoFullSourceComparisons(in: appFixture.appState)
    }
}

@MainActor
private extension AppBackedEditorPerformanceTests {
    struct Fixture {
        let window: NSWindow
        let hostingView: NSView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    struct AppFixture {
        let editor: Fixture
        let appState: AppState
        let session: DocumentSession
        let rootURL: URL
        let documentURL: URL
    }

    static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    static func fixtureText(_ path: String) throws -> String {
        let path = path as NSString
        let file = path.lastPathComponent as NSString
        let fileExtension = file.pathExtension
        let resourceName = file.deletingPathExtension
        let subdirectory = path.deletingLastPathComponent
        let url = try XCTUnwrap(Bundle(for: AppBackedEditorPerformanceTests.self).url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func makeHostedFixture(editor: MarkdownEditorView) async throws -> Fixture {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 240)
        let hostingController = NSHostingController(rootView: editor.frame(
            width: frame.width,
            height: frame.height
        ))
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        let textView = try await waitForTextView(in: hostingController.view)
        let coordinator = try XCTUnwrap(textView.textDelegate as? MarkdownTextViewCoordinator)
        return Fixture(
            window: window,
            hostingView: hostingController.view,
            textView: textView,
            coordinator: coordinator
        )
    }

    func makeAppFixture(
        source: String,
        directoryPrefix: String,
        fileName: String
    ) async throws -> AppFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(directoryPrefix)-\(UUID().uuidString)")
        let documentURL = rootURL.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try source.write(to: documentURL, atomically: true, encoding: .utf8)

        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[documentURL.standardizedFileURL] = session
        appState.recordKnownDiskText(source, for: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        let editor = MarkdownEditorView(
            text: binding.text,
            fileKind: .markdown,
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        return try await AppFixture(
            editor: makeHostedFixture(editor: editor),
            appState: appState,
            session: session,
            rootURL: rootURL,
            documentURL: documentURL
        )
    }

    func waitForTextView(in rootView: NSView) async throws -> MarkdownSTTextView {
        for _ in 0 ..< 200 {
            rootView.layoutSubtreeIfNeeded()
            if let textView = findTextView(in: rootView) {
                return textView
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(findTextView(in: rootView))
    }

    func findTextView(in view: NSView) -> MarkdownSTTextView? {
        if let textView = view as? MarkdownSTTextView {
            return textView
        }
        if let scrollView = view as? NSScrollView,
           let textView = scrollView.documentView as? MarkdownSTTextView
        {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    func tearDownFixture(_ fixture: Fixture) {
        fixture.window.contentViewController = nil
        fixture.window.orderOut(nil)
    }

    func tearDownAppFixture(_ fixture: AppFixture) {
        tearDownFixture(fixture.editor)
        fixture.appState.autosaveTask?.cancel()
        fixture.appState.statisticsTask?.cancel()
        fixture.appState.completionWorkspaceTask?.cancel()
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    func cancelScheduledAppWork(in appState: AppState) {
        appState.autosaveTask?.cancel()
        appState.autosaveTask = nil
        appState.statisticsTask?.cancel()
        appState.statisticsTask = nil
        appState.completionWorkspaceTask?.cancel()
        appState.completionWorkspaceTask = nil
    }

    func assertHostedAppStateStaleIMEBoundary(
        caretLocation: Int,
        expectedPrefix: String
    ) async throws {
        let appFixture = try await makeAppFixture(
            source: "AoldB|suffix",
            directoryPrefix: "AppBackedEditorStaleIMEBoundaryTests",
            fileName: "boundary-\(caretLocation).md"
        )
        defer { tearDownAppFixture(appFixture) }
        await settleScheduledSwiftUIUpdate(in: appFixture.editor)

        try await assertAppBackedStaleIMEBoundaryReconciliation(
            in: appFixture,
            caretLocation: caretLocation,
            expectedPrefix: expectedPrefix
        )
    }

    func assertAppBackedStaleIMEBoundaryReconciliation(
        in fixture: AppFixture,
        caretLocation: Int,
        expectedPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let basePrefix = "AoldB"
        XCTAssertTrue(fixture.session.text.hasPrefix(basePrefix), file: file, line: line)
        let suffix = String(fixture.session.text.dropFirst(basePrefix.count))
        let currentSource = "A\u{1F9EA}B" + suffix
        let expectedSource = expectedPrefix + suffix
        fixture.appState.editorDocumentSourceFullComparisonCounts.removeAll()
        fixture.editor.textView.textSelection = NSRange(location: caretLocation, length: 0)
        fixture.editor.textView.setMarkedText(
            "\u{310A}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(fixture.editor.textView.hasMarkedText(), file: file, line: line)

        fixture.appState.replaceDocumentText(currentSource, in: fixture.session)
        XCTAssertEqual(
            Array(fixture.session.text.utf16),
            Array(currentSource.utf16),
            file: file,
            line: line
        )
        fixture.editor.textView.insertText(
            "\u{81FA}e\u{0301}",
            replacementRange: .notFound
        )
        await settleScheduledSwiftUIUpdate(in: fixture.editor)

        XCTAssertFalse(fixture.editor.textView.hasMarkedText(), file: file, line: line)
        XCTAssertEqual(
            Array(fixture.session.text.utf16),
            Array(expectedSource.utf16),
            file: file,
            line: line
        )
        XCTAssertEqual(
            Array((fixture.editor.textView.text ?? "").utf16),
            Array(expectedSource.utf16),
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            fixture.appState.editorDocumentSourceFullComparisonCounts[.applicationSource, default: 0],
            0,
            "App-source calibration did not observe its production stale comparison",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            fixture.appState.editorDocumentSourceFullComparisonCounts[.nativeView, default: 0],
            0,
            "Native-source calibration did not observe its production reconciliation comparison",
            file: file,
            line: line
        )
    }

    func assertNoFullSourceComparisons(
        in appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            appState.editorDocumentSourceFullComparisonCounts[.applicationSource, default: 0],
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            appState.editorDocumentSourceFullComparisonCounts[.nativeView, default: 0],
            0,
            file: file,
            line: line
        )
    }

    func settleScheduledSwiftUIUpdate(in fixture: Fixture) async {
        await Task.yield()
        fixture.hostingView.layoutSubtreeIfNeeded()
    }

    func measureHostedUpdate(
        in fixture: Fixture,
        operation: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Double {
        let generationBefore = fixture.coordinator.preparedDocumentTransitionGeneration
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        await settleScheduledSwiftUIUpdate(in: fixture)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard let generationBefore,
              let generationAfter = fixture.coordinator.preparedDocumentTransitionGeneration
        else {
            XCTFail("Hosted public editor did not expose a prepared update generation", file: file, line: line)
            return elapsed
        }
        XCTAssertGreaterThan(
            generationAfter,
            generationBefore,
            "Scheduled SwiftUI representable update did not run",
            file: file,
            line: line
        )
        return elapsed
    }

    func measureDocumentSessionPublication(_ operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func measureMarkedTextUpdates(in fixture: Fixture) async -> [Double] {
        fixture.textView.textSelection = NSRange(location: 3, length: 0)
        let first = await measureHostedUpdate(in: fixture) {
            fixture.textView.setMarkedText(
                "\u{310A}",
                selectedRange: NSRange(location: 1, length: 0),
                replacementRange: .notFound
            )
        }
        let second = await measureHostedUpdate(in: fixture) {
            fixture.textView.setMarkedText(
                "\u{310A}\u{3128}",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: .notFound
            )
        }
        let third = await measureHostedUpdate(in: fixture) {
            fixture.textView.setMarkedText(
                "\u{310A}\u{3128}\u{02CB}",
                selectedRange: NSRange(location: 3, length: 0),
                replacementRange: .notFound
            )
        }
        let commit = await measureHostedUpdate(in: fixture) {
            fixture.textView.insertText("\u{8A3B}e\u{0301}", replacementRange: .notFound)
        }
        return [first, second, third, commit]
    }

    func assertFrameBudget(
        _ latency: Double,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard latency < 16 else {
            let message = String(
                format: "WS3B PERF %@ %.3f ms exceeded 16 ms budget",
                label,
                latency
            )
            if Self.isContinuousIntegration {
                print("\(message) on CI; informational per risk R15")
            } else {
                XCTFail(message, file: file, line: line)
            }
            return
        }
    }
}
