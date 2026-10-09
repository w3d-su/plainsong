import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

/// Named acceptance test for scene-scoped action routing, plus stale-focus and
/// read-only negative probes. The fake facade records every `setCommandFocus`
/// revalidation; the fake provider records the exact editor instance it was
/// handed, so a route to another scene's editor would fail identity.
@MainActor
final class IOSShellActionRoutingTests: XCTestCase {
    // MARK: Named test 3

    /// The toolbar routes through the scene router into *this* scene's editor;
    /// a read-only document disables the action and the read-only state is
    /// visible in the deduplicated chrome.
    func testToolbarUsesCurrentSceneEditorAndRefusesReadOnlyDocument() {
        let editor = FakeEditorBinding(canWrite: true, isFocused: true)
        let provider = FakeAuthoringProvider()
        let scene = makeScene(editor: editor, provider: provider)
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)

        // Writable + focused: the current scene's editor receives the command.
        XCTAssertEqual(router.perform(.bold), .performed)
        XCTAssertEqual(provider.performed.map(\.action), [.bold])
        XCTAssertEqual(provider.performed.first?.editor, ObjectIdentifier(editor))

        // Command focus was claimed against the observed binding identity.
        XCTAssertEqual(scene.facadeForTest.setCommandFocusCalls.last?.focused, true)
        XCTAssertEqual(scene.facadeForTest.setCommandFocusCalls.last?.bindingID, editor.bindingID)

        // Flip to read-only through the editor's own access update channel —
        // the same mechanism 05 uses when a file's ACL changes mid-edit.
        editor.updateAccess(for: editor.identity, bindingID: editor.bindingID, generation: 2, canWrite: false)

        XCTAssertFalse(scene.chrome.editorCanWrite)
        XCTAssertEqual(scene.chrome.status, .ready) // read-only badge state is visible
        XCTAssertEqual(router.perform(.bold), .disabled)
        XCTAssertEqual(provider.performed.count, 1) // no second dispatch
        XCTAssertTrue(editor.appliedEdits.isEmpty) // and no write reached the editor
    }

    /// A conflict state must not be writable through the toolbar even if the
    /// editor snapshot still claims canWrite — the facade's state wins for
    /// chrome, and provider gating plus apply() refuse the write path anyway.
    func testConflictedDocumentShowsConflictAndBlocksWrites() throws {
        let editor = FakeEditorBinding(canWrite: true, isFocused: true)
        let provider = FakeAuthoringProvider()
        let conflicted = ShellFixtures.storedDocument(
            state: .conflict(accessGeneration: 2, recovery: nil)
        )
        let scene = makeScene(editor: editor, provider: provider, document: conflicted)
        scene.startObserving()

        XCTAssertEqual(scene.chrome.status, .conflict)
        XCTAssertNotNil(scene.chrome.statusDetail)
        XCTAssertFalse(scene.chrome.editorCanWrite)

        // The merged writability gate vetoes the dispatch entirely — the
        // provider is never asked and nothing reaches the editor.
        let router = IOSShellActionRouter(scene: scene)
        XCTAssertEqual(router.perform(.bold), .disabled)
        XCTAssertTrue(provider.performed.isEmpty)

        // Defense in depth: even a miswired dispatch is refused natively.
        editor.nextRefusal = .readOnly
        let snapshot = editor.captureSnapshot()
        let outcome = try editor.apply(IOSAuthorizedEdit(
            bindingID: XCTUnwrap(snapshot?.bindingID),
            baseRevision: XCTUnwrap(snapshot?.revision),
            selectionGeneration: XCTUnwrap(snapshot?.selectionGeneration),
            accessGeneration: XCTUnwrap(snapshot?.accessGeneration),
            result: MarkdownEditResult(
                replacementRange: NSRange(location: 0, length: 0),
                replacementString: "**x**",
                newSelection: NSRange(location: 0, length: 0)
            ),
            undoActionName: "Bold"
        ))
        XCTAssertEqual(outcome, .refused(.readOnly))
    }

    /// Focus claimed by another scene's surface (or none) drops the action
    /// rather than retargeting it — the macOS "commands no-op outside the
    /// editor" rule, scene-scoped.
    func testUnfocusedEditorDropsAction() {
        let editor = FakeEditorBinding(canWrite: true, isFocused: false)
        let provider = FakeAuthoringProvider()
        let scene = makeScene(editor: editor, provider: provider)
        scene.startObserving()

        let router = IOSShellActionRouter(scene: scene)
        XCTAssertEqual(router.perform(.bold), .notFocused)
        XCTAssertTrue(provider.performed.isEmpty)
        XCTAssertTrue(scene.facadeForTest.setCommandFocusCalls.isEmpty)
    }

    /// The facade rejecting the focus claim (binding swapped between snapshot
    /// and dispatch) must abort routing — stale editors never receive commands.
    func testRejectedFocusClaimAbortsDispatch() {
        let editor = FakeEditorBinding(canWrite: true, isFocused: true)
        let provider = FakeAuthoringProvider()
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        facade.commandFocusResult = false
        let scene = IOSShellSceneState(
            facade: facade,
            surfaces: IOSShellFeatureSurfaces(authoring: provider)
        )
        scene.startObserving()

        let router = IOSShellActionRouter(scene: scene)
        XCTAssertEqual(router.perform(.bold), .focusRejected)
        XCTAssertTrue(provider.performed.isEmpty)
    }

    /// Detachment fences the route: after the editor reports `detached` for the
    /// observed binding, further actions can't reach it.
    func testDetachedBindingDropsSubsequentActions() {
        let editor = FakeEditorBinding(canWrite: true, isFocused: true)
        let provider = FakeAuthoringProvider()
        let scene = makeScene(editor: editor, provider: provider)
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)

        XCTAssertEqual(router.perform(.bold), .performed)

        editor.detach(expected: editor.identity, bindingID: editor.bindingID)
        // The scene clears its snapshot on the matching detach event.
        XCTAssertNil(scene.editorSnapshot)

        XCTAssertEqual(router.perform(.italic), .notFocused)
        XCTAssertEqual(provider.performed.count, 1)
    }

    /// Undo/redo are authoring mutations too: read-only editors keep them off.
    func testUndoRedoRespectCanWrite() {
        let editor = FakeEditorBinding(canWrite: false, isFocused: true)
        let scene = makeScene(editor: editor)
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)

        XCTAssertEqual(router.undo(), .disabled)
        XCTAssertEqual(router.redo(), .disabled)
        XCTAssertEqual(editor.undoCount, 0)
        XCTAssertEqual(editor.redoCount, 0)
    }

    /// `.find` is a presentation affordance, not a text mutation — it opens
    /// the hosted find sheet instead of touching the editor.
    func testFindActionPresentsSheet() {
        let scene = makeScene(editor: FakeEditorBinding())
        scene.startObserving()
        let router = IOSShellActionRouter(scene: scene)

        XCTAssertEqual(router.perform(.find), .presentedSheet)
        XCTAssertEqual(scene.presentation, .findReplace)
    }

    // MARK: Helpers

    private func makeScene(
        editor: FakeEditorBinding? = nil,
        provider: FakeAuthoringProvider? = nil,
        document: IOSStoredDocumentSnapshot? = nil
    ) -> IOSShellSceneState {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: document ?? ShellFixtures.storedDocument()
            ),
            capabilities: IOSSceneCapabilities(
                editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        return IOSShellSceneState(
            facade: facade,
            surfaces: IOSShellFeatureSurfaces(authoring: provider)
        )
    }
}

private extension IOSShellSceneState {
    /// Tests reach the concrete fake through a typed accessor instead of
    /// casting at every call site.
    var facadeForTest: FakeSceneFacade {
        facade as! FakeSceneFacade // swiftlint:disable:this force_cast
    }
}
