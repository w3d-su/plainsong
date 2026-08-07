import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// F8 App side: what the editor is asked to decorate, and when it is asked to stop.
@MainActor
final class EditorFindMatchHighlightAppTests: XCTestCase {
    private func makeAppState(text: String) -> AppState {
        let url = URL(fileURLWithPath: "/tmp/plainsong-find-highlight-\(UUID().uuidString).md")
        let session = DocumentSession(text: text, url: url, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        return appState
    }

    private func openFindBar(_ appState: AppState, query: String) {
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        ui.queryText = query
        appState.setEditorFindUI(ui)
        appState.ensureEditorFindSessionObserverInstalled()
        appState.syncEditorFindControllerDocument()
        if !query.isEmpty {
            appState.pushEditorFindQueryToController()
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testHighlightRequestCarriesEveryMatchAndTheZeroBasedCurrentIndex() async throws {
        let text = "alpha needle beta needle gamma needle"
        let appState = makeAppState(text: text)
        openFindBar(appState, query: "needle")
        try await waitUntil("three matches") { appState.editorFindHost.controller.session?.total == 3 }

        let request = try XCTUnwrap(appState.editorFindMatchHighlight)
        let expected = [
            NSRange(location: 6, length: 6),
            NSRange(location: 18, length: 6),
            NSRange(location: 31, length: 6),
        ]
        XCTAssertEqual(request.matches, expected)
        let ordinal = try XCTUnwrap(appState.editorFindHost.controller.session?.currentOrdinal)
        XCTAssertEqual(
            request.currentIndex,
            ordinal - 1,
            "currentOrdinal is the 1-based UI ordinal; an off-by-one here paints the wrong match"
        )
    }

    func testSteppingToTheNextMatchMovesTheCurrentIndex() async throws {
        let appState = makeAppState(text: "alpha needle beta needle")
        openFindBar(appState, query: "needle")
        try await waitUntil("two matches") { appState.editorFindHost.controller.session?.total == 2 }
        let before = try XCTUnwrap(appState.editorFindMatchHighlight)

        appState.editorFindNext()

        let after = try XCTUnwrap(appState.editorFindMatchHighlight)
        XCTAssertEqual(after.matches, before.matches)
        XCTAssertNotEqual(
            after.currentIndex,
            before.currentIndex,
            "the current match must move, otherwise the editor skips re-applying decoration"
        )
        XCTAssertNotEqual(after, before, "an unchanged request is skipped by the editor as a no-op")
    }

    func testClosingTheBarStopsRequestingDecoration() async throws {
        let appState = makeAppState(text: "alpha needle beta")
        openFindBar(appState, query: "needle")
        try await waitUntil("one match") { appState.editorFindHost.controller.session?.total == 1 }
        XCTAssertNotNil(appState.editorFindMatchHighlight)

        appState.closeEditorFindBar()

        XCTAssertNil(
            appState.editorFindMatchHighlight,
            "a closed bar must clear decoration rather than leave the last query lit"
        )
    }

    func testNoDecorationIsRequestedForAnEmptyOrUnmatchedQuery() async throws {
        let appState = makeAppState(text: "alpha beta gamma")
        openFindBar(appState, query: "")
        XCTAssertNil(appState.editorFindMatchHighlight, "an empty query decorates nothing")

        var ui = appState.editorFindHost.ui
        ui.queryText = "zzz-absent"
        appState.setEditorFindUI(ui)
        appState.pushEditorFindQueryToController()
        try await waitUntil("zero matches") {
            appState.editorFindHost.controller.session?.total == 0
        }

        XCTAssertNil(appState.editorFindMatchHighlight, "a query with no matches decorates nothing")
    }
}
