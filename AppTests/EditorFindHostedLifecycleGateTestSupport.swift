import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Probes shared by the hosted F4b lifecycle and F7 focus gates. Everything here reads live
/// AppKit / EditorKit state from the production `WorkspaceWindow` a test mounted; nothing
/// replaces a production path.
@MainActor
extension EditorFindHostedGateTests {
    /// The production editor text view mounted in `window`.
    func editorTextView(in window: NSWindow) -> MarkdownSTTextView? {
        firstDescendant(of: MarkdownSTTextView.self, in: window.contentView) {
            $0.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
        }
    }

    /// The EditorKit coordinator driving that editor, including its navigation state machine.
    func editorCoordinator(in window: NSWindow) -> MarkdownTextViewCoordinator? {
        editorTextView(in: window)?.textDelegate as? MarkdownTextViewCoordinator
    }

    /// The selection the hosted editor has actually applied, regardless of first responder.
    func appliedRange(in window: NSWindow) -> NSRange? {
        EditorSelectionProbe.appliedEditorSelection(in: window)?.range
    }

    /// The document identity the hosted editor currently renders.
    func editorIdentity(in window: NSWindow) -> EditorDocumentIdentity? {
        EditorSelectionProbe.appliedEditorSelection(in: window)?.documentIdentity
    }

    func matchRanges(of pattern: String, in source: String) -> [NSRange] {
        TextSearchEngine.matches(
            in: source,
            query: TextSearchQuery(pattern: pattern),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)
    }

    /// Samples `predicate` on every retry-loop cadence for `duration` and fails the first time
    /// it stops holding. Focus retries and navigation retries both run on ≤ 50 ms cadences,
    /// so the default window spans many of their iterations.
    func assertRemains(
        _ description: String,
        for duration: TimeInterval = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line,
        diagnostics: @escaping @MainActor () -> String = { "" },
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            guard predicate() else {
                XCTFail("Stopped holding: \(description) \(diagnostics())", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        } while Date() < deadline
        XCTAssertTrue(predicate(), "Stopped holding: \(description)", file: file, line: line)
    }

    /// ⌘G from the bar. Returns the request it published on the **shared** App channel.
    ///
    /// Publishing is synchronous; SwiftUI hands the command to the hosted editor only on its
    /// next update, so a transition entered in the same main-actor turn runs while this
    /// navigation is published but not yet applied.
    func publishFindStep(
        _ appState: AppState,
        expecting selection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> EditorNavigationRequest {
        appState.stepEditorFindFromBarControl(.next)
        guard case let .navigate(request)? = appState.editorNavigationCommand else {
            XCTFail("⌘G did not publish on the shared navigation channel", file: file, line: line)
            throw HostedGateFailure.missingPublishedNavigation
        }
        XCTAssertEqual(request.selection, selection, file: file, line: line)
        XCTAssertFalse(request.shouldFocusEditor, file: file, line: line)
        return request
    }

    /// The transition must have superseded `stale` on the shared channel with a newer cancel.
    @discardableResult
    func assertSharedChannelCancels(
        _ stale: EditorNavigationRequest,
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UInt64? {
        guard case let .cancel(id)? = appState.editorNavigationCommand else {
            let found = String(describing: appState.editorNavigationCommand)
            XCTFail("Expected a cancel on the shared channel, found \(found)", file: file, line: line)
            return nil
        }
        XCTAssertGreaterThan(id, stale.id, "The cancel must outrank the published navigation", file: file, line: line)
        return id
    }

    /// Late re-publication of a navigation carrying a pre-transition ID — even retargeted at
    /// the post-transition identity — must not move the hosted editor's selection.
    func assertPreTransitionNavigationCannotLand(
        _ stale: EditorNavigationRequest,
        retargetedAt identity: EditorDocumentIdentity,
        cancelID: UInt64,
        appState: AppState,
        window: NSWindow,
        selection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let coordinator = try XCTUnwrap(editorCoordinator(in: window), file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            coordinator.navigationState.highestObservedCommandID ?? 0,
            cancelID,
            "The hosted editor must have observed the transition's cancel",
            file: file,
            line: line
        )
        XCTAssertNil(coordinator.navigationState.pendingRequest, file: file, line: line)

        appState.editorNavigationCommand = .navigate(EditorNavigationRequest(
            id: stale.id,
            documentIdentity: identity,
            selection: stale.selection,
            shouldFocusEditor: false
        ))
        try await assertRemains(
            "a pre-transition navigation ID stays unapplied",
            file: file,
            line: line
        ) {
            self.appliedRange(in: window) == selection
                && coordinator.navigationState.pendingRequest == nil
        }
    }

    /// Bar visibility half of F4b: the *same* production query field instance is still
    /// mounted, still shows the query, and the hosted editor did not auto-jump.
    func assertFindBarStayedMounted(
        _ field: NSTextField,
        query: String,
        selection: NSRange,
        appState: AppState,
        window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, file: file, line: line)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, query, file: file, line: line)
        try await assertRemains(
            "find bar stays mounted without an auto-jump",
            file: file,
            line: line
        ) {
            self.findQueryField(in: window) === field
                && field.stringValue == query
                && self.appliedRange(in: window) == selection
        }
    }
}

enum HostedGateFailure: Error {
    case missingPublishedNavigation
}
