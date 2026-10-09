import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import UIKit
import XCTest

/// Named acceptance tests for handoff 10's retention guarantees, plus the
/// 900 pt content-width policy boundary. Everything runs on test doubles —
/// simulator/device rotation, resizing and hardware-keyboard checks stay on
/// the manual gate list in docs/ios/evidence/lane-10.
@MainActor
final class IOSShellLayoutTests: XCTestCase {
    // MARK: Named test 1

    /// Repeated compact ↔ wide transitions must reuse the one editor host view
    /// and the one preview host view. The hosted-view cache keys on capability
    /// identity, so a layout change can never run a factory twice.
    func testShellUsesSingleEditorAndPreviewAcrossLayoutChanges() {
        var editorFactoryCalls = 0
        var previewFactoryCalls = 0
        let editorView = UIView()
        let previewView = UIView()

        let editor = FakeEditorBinding()
        let preview = FakePreviewController()
        var surfaces = IOSShellFeatureSurfaces()
        surfaces.makeEditorView = { _ in editorFactoryCalls += 1; return editorView }
        surfaces.makePreviewView = { _ in previewFactoryCalls += 1; return previewView }

        let scene = makeScene(editor: editor, preview: preview, surfaces: surfaces)
        scene.startObserving()

        let firstEditorHost = scene.editorHostView
        let firstPreviewHost = scene.previewHostView
        XCTAssertTrue(firstEditorHost === editorView)
        XCTAssertTrue(firstPreviewHost === previewView)

        for _ in 0 ..< 20 {
            scene.updateLayout(prefersRegularWidth: true, contentWidth: 1024) // side by side
            scene.updateLayout(prefersRegularWidth: true, contentWidth: 500) // narrow → toggle
            scene.updateLayout(prefersRegularWidth: false, contentWidth: 1024) // compact → toggle
            XCTAssertTrue(scene.editorHostView === firstEditorHost)
            XCTAssertTrue(scene.previewHostView === firstPreviewHost)
        }

        XCTAssertEqual(editorFactoryCalls, 1)
        XCTAssertEqual(previewFactoryCalls, 1)
        XCTAssertEqual(editor.detachCalls.count, 0)
        XCTAssertEqual(editor.attachCount, 0)

        // The container must also keep both native views mounted across modes.
        let container = IOSDualPaneContainerView()
        container.setPanes(editor: firstEditorHost, preview: firstPreviewHost)
        for mode: IOSDualPaneContainerView.Mode in [
            .sideBySide, .single(.preview), .single(.source), .sideBySide, .single(.source),
        ] {
            container.apply(mode: mode)
        }
        XCTAssertTrue(container.editorView === firstEditorHost)
        XCTAssertTrue(container.previewView === firstPreviewHost)
        XCTAssertTrue(firstEditorHost?.superview === container)
        XCTAssertTrue(firstPreviewHost?.superview === container)
    }

    // MARK: Named test 2

    /// Layout transitions touch only container geometry/visibility: no edit is
    /// applied, no attach/detach happens, and the editor's selection, visible
    /// range and undo target are bit-for-bit the same before and after.
    func testLayoutTransitionRetainsSelectionScrollAndUndo() {
        let editor = FakeEditorBinding(
            text: "# draft\n\nbody\n",
            selection: NSRange(location: 9, length: 2),
            visibleRange: NSRange(location: 2, length: 8)
        )
        let scene = makeScene(editor: editor, preview: FakePreviewController())
        scene.startObserving()

        let before = editor.captureSnapshot()
        let versionBefore = editor.session.version

        let transitions: [(Bool, CGFloat)] = [
            (true, 1200), (true, 899), (false, 390), (true, 900), (false, 844), (true, 601),
        ]
        for (regular, width) in transitions {
            scene.updateLayout(prefersRegularWidth: regular, contentWidth: width)
        }

        let after = editor.captureSnapshot()
        XCTAssertEqual(after?.selection, before?.selection)
        XCTAssertEqual(after?.visibleRange, before?.visibleRange)
        XCTAssertEqual(after?.selectionGeneration, before?.selectionGeneration)
        XCTAssertEqual(after?.hasMarkedText, before?.hasMarkedText)
        XCTAssertEqual(editor.session.version, versionBefore)
        XCTAssertTrue(editor.appliedEdits.isEmpty)
        XCTAssertEqual(editor.attachCount, 0)
        XCTAssertTrue(editor.detachCalls.isEmpty)

        // Undo still routes to the same live editor instance.
        let router = IOSShellActionRouter(scene: scene)
        XCTAssertEqual(router.undo(), .performed)
        XCTAssertEqual(editor.undoCount, 1)
    }

    // MARK: 900 pt width-boundary policy

    func testLayoutPolicyFlipsExactlyAtNineHundredPoints() {
        let scene = makeScene()

        scene.updateLayout(prefersRegularWidth: true, contentWidth: 899)
        XCTAssertEqual(scene.layout, .single(.source))

        scene.updateLayout(prefersRegularWidth: true, contentWidth: 900)
        XCTAssertEqual(scene.layout, .sideBySide)

        scene.updateLayout(prefersRegularWidth: true, contentWidth: 899.9)
        XCTAssertEqual(scene.layout, .single(.source))
    }

    func testCompactWidthAlwaysUsesToggleRegardlessOfContentWidth() {
        let scene = makeScene()

        scene.updateLayout(prefersRegularWidth: false, contentWidth: 1400)
        XCTAssertEqual(scene.layout, .single(.source))

        scene.showPane(.preview)
        scene.updateLayout(prefersRegularWidth: false, contentWidth: 1400)
        XCTAssertEqual(scene.layout, .single(.preview))
    }

    func testPreferredPaneSurvivesRoundTripsThroughSideBySide() {
        let scene = makeScene()

        scene.showPane(.preview)
        scene.updateLayout(prefersRegularWidth: true, contentWidth: 400)
        XCTAssertEqual(scene.layout, .single(.preview))

        scene.updateLayout(prefersRegularWidth: true, contentWidth: 1024)
        XCTAssertEqual(scene.layout, .sideBySide)

        // Returning to toggle restores the pane the user last chose.
        scene.updateLayout(prefersRegularWidth: true, contentWidth: 500)
        XCTAssertEqual(scene.layout, .single(.preview))
    }

    /// The container's hidden flags track the mode — hidden panes leave both
    /// the touch and the accessibility tree while staying mounted.
    func testContainerVisibilityTracksModeWithoutUnmounting() {
        let editor = UIView()
        let preview = UIView()
        let container = IOSDualPaneContainerView()
        container.setPanes(editor: editor, preview: preview)

        container.apply(mode: .single(.source))
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(preview.isHidden)

        container.apply(mode: .single(.preview))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(preview.isHidden)

        container.apply(mode: .sideBySide)
        XCTAssertFalse(editor.isHidden)
        XCTAssertFalse(preview.isHidden)

        XCTAssertTrue(editor.superview === container)
        XCTAssertTrue(preview.superview === container)
    }

    /// A different capability identity is the only thing allowed to swap the
    /// retained host — a real attach/retarget, not a layout change.
    func testCapabilityIdentityChangeReplacesRetainedHost() {
        var surfaces = IOSShellFeatureSurfaces()
        surfaces.makeEditorView = { _ in UIView() }

        let first = FakeEditorBinding()
        let second = FakeEditorBinding()
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: first, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade, surfaces: surfaces)
        scene.startObserving()

        let firstHost = scene.editorHostView
        facade.capabilities = IOSSceneCapabilities(
            editor: second, documents: nil, workspace: nil, preview: nil, assets: nil
        )
        let secondHost = scene.editorHostView

        XCTAssertNotNil(firstHost)
        XCTAssertNotNil(secondHost)
        XCTAssertFalse(firstHost === secondHost)
    }

    // MARK: Helpers

    private func makeScene(
        editor: FakeEditorBinding? = nil,
        preview: FakePreviewController? = nil,
        surfaces: IOSShellFeatureSurfaces = IOSShellFeatureSurfaces()
    ) -> IOSShellSceneState {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: editor, documents: nil, workspace: nil, preview: preview, assets: nil
            )
        )
        return IOSShellSceneState(facade: facade, surfaces: surfaces)
    }
}
