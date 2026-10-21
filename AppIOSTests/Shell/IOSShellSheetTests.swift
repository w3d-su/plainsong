import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

/// Named acceptance test for sheet lifecycle: dismissal is never a commit.
/// Swipe-down, a Cancel button, and a document switch all funnel through
/// `dismissPresentation`, which notifies hosted content exactly once.
@MainActor
final class IOSShellSheetTests: XCTestCase {
    // MARK: Named test 4

    /// A cancelled authoring/image pending flow produces no edit and no insert.
    /// The hosted surface registers `onDismiss`; the shell fires it once and
    /// never performs a commit on the sheet's behalf.
    func testDismissedSheetDoesNotCommitPendingEdit() {
        let editor = FakeEditorBinding()
        let provider = FakeAuthoringProvider()
        let inserter = FakeImageInserter()
        let scene = makeScene(editor: editor, provider: provider, inserter: inserter)
        scene.startObserving()

        // The 09-hosted picker registers its cancel hook on presentation.
        var dismissNotifications = 0
        scene.present(.imagePicker)
        XCTAssertEqual(scene.presentation, .imagePicker)
        let context = scene.sheetContext
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.editor as? FakeEditorBinding === editor)
        context?.onDismiss { dismissNotifications += 1 }

        // User cancels (swipe-down, Cancel, or Escape — same path).
        scene.dismissPresentation()

        XCTAssertEqual(dismissNotifications, 1)
        XCTAssertNil(scene.presentation)
        XCTAssertNil(scene.sheetContext)
        XCTAssertTrue(provider.performed.isEmpty)
        XCTAssertTrue(editor.appliedEdits.isEmpty)
        XCTAssertEqual(inserter.insertCalls, 0)
        XCTAssertEqual(editor.session.version, 0)
    }

    /// The image flow's context carries the document's directory and the
    /// captured grant — captured at presentation time so a later caret or
    /// selection move cannot retarget the pending insert.
    func testImagePickerContextCapturesDestinationAndGrant() {
        let grant = ShellFixtures.grant()
        var surfaces = IOSShellFeatureSurfaces(imageInsertion: FakeImageInserter())
        surfaces.currentGrant = { grant }
        let document = ShellFixtures.storedDocument(path: "posts/entry.md")
        let scene = makeScene(document: document, surfaces: surfaces)
        scene.startObserving()

        scene.present(.imagePicker)

        XCTAssertEqual(
            scene.sheetContext?.destination?.relativePath,
            "posts"
        )
        XCTAssertEqual(scene.sheetContext?.grant?.workspaceID, grant.workspaceID)
        XCTAssertEqual(scene.sheetContext?.grant?.accessGeneration, grant.accessGeneration)
    }

    /// Non-image sheets get no image context — frontmatter/find don't consume
    /// grant or destination.
    func testFrontmatterContextCarriesNoImageGrant() {
        var surfaces = IOSShellFeatureSurfaces(imageInsertion: FakeImageInserter())
        surfaces.currentGrant = { ShellFixtures.grant() }
        let scene = makeScene(surfaces: surfaces)
        scene.startObserving()

        scene.present(.frontmatter)

        XCTAssertNil(scene.sheetContext?.destination)
        XCTAssertNil(scene.sheetContext?.grant)
    }

    /// Double-dismissal is idempotent — SwiftUI's own dismiss animation plus a
    /// Cancel button can both reach the shell; hosted content must still hear
    /// exactly one notification.
    func testDismissalIsExactlyOnce() {
        let scene = makeScene()
        scene.startObserving()
        var dismissNotifications = 0

        scene.present(.findReplace)
        scene.sheetContext?.onDismiss { dismissNotifications += 1 }
        scene.dismissPresentation()
        scene.dismissPresentation()

        XCTAssertEqual(dismissNotifications, 1)
    }

    /// Replacing one sheet with another dismisses the first — its cancel
    /// contract still fires, exactly once.
    func testReplacingSheetCancelsThePreviousContext() {
        let scene = makeScene()
        scene.startObserving()
        var firstDismissed = 0

        scene.present(.frontmatter)
        scene.sheetContext?.onDismiss { firstDismissed += 1 }
        scene.present(.findReplace)

        XCTAssertEqual(firstDismissed, 1)
        XCTAssertEqual(scene.presentation, .findReplace)
    }

    /// A document switch while a sheet is up cancels it — the pending proposal
    /// was bound to the old document's capture and could only refuse anyway.
    func testDocumentSwitchCancelsPendingSheet() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: FakeEditorBinding(), documents: nil, workspace: nil,
                preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()
        var dismissed = 0

        scene.present(.frontmatter)
        scene.sheetContext?.onDismiss { dismissed += 1 }

        facade.emit(ShellFixtures.sceneSnapshot(
            document: ShellFixtures.storedDocument(path: "other.md")
        ))

        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(scene.presentation)
    }

    // MARK: Helpers

    private func makeScene(
        document: IOSStoredDocumentSnapshot? = nil,
        editor: FakeEditorBinding? = nil,
        provider: FakeAuthoringProvider? = nil,
        inserter: FakeImageInserter? = nil,
        surfaces: IOSShellFeatureSurfaces? = nil
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
            surfaces: surfaces ?? IOSShellFeatureSurfaces(
                authoring: provider,
                imageInsertion: inserter
            )
        )
    }
}
