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
        // Opt-in CI mimicry (handoff 27b): on CI the real NSApp.keyWindow differed from the
        // designated test window. A foreign borderless window made key after designation
        // reproduces that split for any product path still reading NSApp.keyWindow itself.
        if ProcessInfo.processInfo.environment["PLAINSONG_HOSTED_FOREIGN_KEY_WINDOW"] == "1" {
            let foreign = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            foreign.isReleasedWhenClosed = false
            foreign.makeKeyAndOrderFront(nil)
            addTeardownBlock { @MainActor in
                foreign.orderOut(nil)
                foreign.close()
            }
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
        if !hosted.appState.editorFindHost.ui.isReplaceExpanded {
            disclosure.performClick(nil)
        }
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
        let appState = hosted.appState
        let state = appState.editorFindHost.replaceBatch
        state.onChunkForTesting = { _ in hold.checkpoint() }
        addTeardownBlock { @MainActor in
            hold.release()
            state.onChunkForTesting = nil
        }
        // Handoff 27b: when the held-checkpoint wait below times out, this also reports the
        // Replace All button's live state and the authority/status counters captured just
        // before the press. `hostedFindTimeoutState` covers the rest of App's state.
        weak var weakAppState = appState
        weak var weakWindow = hosted.window
        let serialAtPress = appState.editorFindHost.replaceStatusSerial
        let generationAtPress = appState.editorReplaceAuthorityGeneration
        hostedTimeoutDiagnostics.append { [weak self] in
            guard let self, let appState = weakAppState, let window = weakWindow else {
                return "Hosted Replace fixture released before the timeout report"
            }
            let button = barButton(EditorFindAccessibility.replaceAllButton, in: window)
            return "replaceAllButton mounted=\(button != nil) "
                + "enabled=\(String(describing: button?.isEnabled)) "
                + "hidden=\(String(describing: button?.isHidden)) "
                + "buttonWindow=\(String(describing: button?.window?.windowNumber)) "
                + "designatedWindow=\(window.windowNumber)\n"
                + "countersAtPress serial=\(serialAtPress) generation=\(generationAtPress); "
                + "atTimeout serial=\(appState.editorFindHost.replaceStatusSerial) "
                + "generation=\(appState.editorReplaceAuthorityGeneration) "
                + "replaceAllTask=\(appState.editorFindHost.replaceAllTask != nil)"
        }
        try await start()
        try await waitUntil("the bar's Replace All reaches its held preparation checkpoint") { hold.isEntered }
        XCTAssertFalse(hold.didRunOnMainThread)
        return hold
    }

    /// §5.5: a composing owner refuses Replace with `.markedText` before App evaluates any
    /// authorization, with zero effect and no authority input change.
    func assertMarkedTextRefusal(
        _ hosted: HostedReplaceWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let appState = hosted.appState
        let editor = try hostedEditor(hosted)
        appState.editorFindHost.replaceAuthority.lastAuthorizationRecord = nil
        let before = EditorReplaceEffectSnapshot(appState, textView: editor)
        let generation = appState.editorReplaceAuthorityGeneration
        XCTAssertEqual(appState.performEditorReplace(replacement: "HIT"), .markedText, file: file, line: line)
        XCTAssertNil(
            appState.editorFindHost.replaceAuthority.lastAuthorizationRecord,
            "composition refuses before any authorization",
            file: file,
            line: line
        )
        XCTAssertEqual(EditorReplaceEffectSnapshot(appState, textView: editor), before, file: file, line: line)
        XCTAssertEqual(appState.editorReplaceAuthorityGeneration, generation, file: file, line: line)
    }
}
