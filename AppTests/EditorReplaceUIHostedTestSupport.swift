import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Replace PR H hosted support: production `WorkspaceWindow`s, the real replacement row, and
/// its real controls. Bar controls are owned AppKit views, clicked through `performClick`, and
/// the fields are driven through their real field editors — never by calling the App intent
/// behind them. (SwiftUI builds no in-process accessibility tree without an assistive client,
/// which is one reason the row's buttons are AppKit.)
@MainActor
extension EditorFindHostedGateTests {
    /// Installs every key-window seam for `appState`, read live from `group`: EditorKit's
    /// dispatcher and Find's AppKit responder branch. Only *which window is key* is
    /// designated; first responders, field editors and delivery stay real, and the
    /// command-context override is removed so the production eligibility check runs.
    func installProductionKeyWindowSeams(_ appState: AppState, group: HostedWorkspaceGroup) {
        designateReplaceKeyWindow(in: group)
        appState.editorFindHost.commandContextOverride = nil
        appState.editorFindHost.keyWindowOverride = { [weak group] in
            group?.windows.first(where: \.isKeyWindow)
        }
        addTeardownBlock { @MainActor in
            appState.editorFindHost.keyWindowOverride = nil
            appState.editorFindHost.keyWindowNumberOverride = nil
        }
    }

    /// The menu dispatchers read `PlainsongAppServices.appState`; point it at the fixture.
    func routeMenuCommands(to appState: AppState) {
        let previous = PlainsongAppServices.appState
        PlainsongAppServices.appState = appState
        addTeardownBlock { @MainActor in
            PlainsongAppServices.appState = previous
        }
    }

    func replacementField(in window: NSWindow) -> NSTextField? {
        firstDescendant(of: NSTextField.self, in: window.contentView) {
            $0.accessibilityIdentifier() == EditorFindAccessibility.replacementField
        }
    }

    func waitForReplacementField(in window: NSWindow) async throws -> NSTextField {
        try await waitUntil("production replacement field mounts") {
            self.replacementField(in: window) != nil
        }
        return try XCTUnwrap(replacementField(in: window))
    }

    /// An owned AppKit bar control (`EditorFindBarButton`) in `window`.
    func barButton(_ identifier: String, in window: NSWindow) -> NSButton? {
        firstDescendant(of: NSButton.self, in: window.contentView) {
            $0.accessibilityIdentifier() == identifier
        }
    }

    func waitForBarButton(_ identifier: String, in window: NSWindow) async throws -> NSButton {
        try await waitUntil("bar control \(identifier) mounts") {
            self.barButton(identifier, in: window) != nil
        }
        return try XCTUnwrap(barButton(identifier, in: window))
    }

    func isReplacementFieldFirstResponder(in window: NSWindow) -> Bool {
        guard let field = replacementField(in: window), let first = window.firstResponder else {
            return false
        }
        return first === field || first === field.currentEditor()
    }

    /// A hosted workspace with the bar open on `query`, the replacement row expanded through
    /// the real disclosure, `replacement` typed into the real field, production key-window
    /// seams installed, and Edit-menu commands routed to its `AppState`. The editor keeps the
    /// current match selected, as `makeHostedBatchWorkspace` left it.
    func makeHostedReplaceRow(
        source: String = "hit one hit two",
        query: String = "hit",
        replacement: String? = "NEW",
        layoutMode: EditorLayoutMode = .sourceOnly
    ) async throws -> HostedReplaceWorkspace {
        let hosted = try await makeHostedBatchWorkspace(source: source, query: query, layoutMode: layoutMode)
        installProductionKeyWindowSeams(hosted.appState, group: hosted.group)
        routeMenuCommands(to: hosted.appState)
        let disclosure = try await waitForBarButton(EditorFindAccessibility.replaceDisclosure, in: hosted.window)
        disclosure.performClick(nil)
        XCTAssertTrue(hosted.appState.editorFindHost.ui.isReplaceExpanded)
        _ = try await waitForReplacementField(in: hosted.window)
        if let replacement {
            try typeReplacement(replacement, in: hosted.window)
        }
        return hosted
    }

    /// Types into the real replacement field through its field editor, so the value reaches
    /// App through `controlTextDidChange` exactly as keyboard input does.
    func typeReplacement(_ text: String, in window: NSWindow) throws {
        let field = try XCTUnwrap(replacementField(in: window))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// The live field editor of the replacement field (making it first responder if needed).
    func replacementFieldEditor(in window: NSWindow) throws -> NSTextView {
        let field = try XCTUnwrap(replacementField(in: window))
        if !isReplacementFieldFirstResponder(in: window) {
            XCTAssertTrue(window.makeFirstResponder(field))
        }
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }

    /// Clicks a real bar control: AppKit's own `performClick`, the same target/action path a
    /// mouse click or a Full Keyboard Access Space press runs.
    func click(_ identifier: String, in window: NSWindow) async throws {
        let button = try await waitForBarButton(identifier, in: window)
        XCTAssertTrue(button.isEnabled, "\(identifier) must be enabled to be clicked")
        button.performClick(nil)
    }

    /// Waits for the bar's own Replace All task (started by a button or menu) to finish.
    func awaitBarReplaceAll(_ appState: AppState) async {
        await appState.editorFindHost.replaceAllTask?.value
    }

    /// Starts the bar's Replace All against a held preparation worker and waits until the
    /// worker is parked at its first checkpoint, off the main actor.
    func startHeldBarReplaceAll(
        _ hosted: HostedReplaceWorkspace,
        start: @MainActor () async throws -> Void
    ) async throws -> HostedReplaceBatchHold {
        let hold = HostedReplaceBatchHold()
        let state = hosted.appState.editorFindHost.replaceBatch
        state.onChunkForTesting = { _ in hold.checkpoint() }
        addTeardownBlock { @MainActor in
            hold.release()
            state.onChunkForTesting = nil
        }
        try await start()
        try await waitUntil("the bar's Replace All reaches its held preparation checkpoint") { hold.isEntered }
        XCTAssertFalse(hold.didRunOnMainThread)
        return hold
    }
}
