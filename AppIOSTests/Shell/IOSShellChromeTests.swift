import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

/// Chrome projection, navigation delegation and workspace-entry gating.
/// The shell's own state machine is covered so a fake facade can't fake a
/// success path the real facade would refuse.
@MainActor
final class IOSShellChromeTests: XCTestCase {
    // MARK: Chrome projection

    func testChromeProjectsDocumentStatusWithoutDocumentData() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: ShellFixtures.storedDocument(
                    path: "posts/today.md", isDirty: true, fileKind: .mdx
                )
            ),
            capabilities: IOSSceneCapabilities(
                editor: FakeEditorBinding(canWrite: false, isFocused: false),
                documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        XCTAssertEqual(scene.chrome.status, .ready)
        XCTAssertEqual(scene.chrome.documentTitle, "today.md")
        XCTAssertEqual(scene.chrome.documentKind, .mdx)
        XCTAssertTrue(scene.chrome.isDirty)
        XCTAssertFalse(scene.chrome.editorFocused)
        XCTAssertFalse(scene.chrome.editorHasMarkedText)
        XCTAssertTrue(scene.chrome.hasDocument)
    }

    func testUnavailableDocumentExposesReasonNotASource() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: ShellFixtures.storedDocument(
                    state: .unavailable(
                        accessGeneration: 3,
                        reason: .access(.permissionDenied)
                    )
                )
            ),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        XCTAssertEqual(scene.chrome.status, .unavailable)
        XCTAssertNotNil(scene.chrome.statusDetail)
        XCTAssertFalse(scene.chrome.editorCanWrite)
        // The shell never derives a source string from an unavailable doc.
        XCTAssertTrue(scene.chrome.hasDocument) // still rendered (banner + retry)
    }

    func testChromeDeduplicatesEquivalentSnapshots() throws {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: ShellFixtures.storedDocument()
            ),
            capabilities: IOSSceneCapabilities(
                editor: FakeEditorBinding(), documents: nil, workspace: nil,
                preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        var publications = 0
        let cancellable = scene.$chrome.sink { _ in publications += 1 }
        let baseline = publications

        // A snapshot event whose deduplicated projection is identical must not
        // republish chrome (keystroke-frequency events stay off the UI pass).
        let editor = try XCTUnwrap(facade.capabilities
            .editor as? FakeEditorBinding) // swiftlint:disable:this force_cast
        editor.selectionGeneration += 1 // invisible to chrome
        editor.emitSnapshot()

        XCTAssertEqual(publications, baseline)

        // A chrome-visible fact (dirty) does republish.
        facade.emit(ShellFixtures.sceneSnapshot(
            document: ShellFixtures.storedDocument(isDirty: true)
        ))
        XCTAssertEqual(publications, baseline + 1)
        _ = cancellable
    }

    // MARK: Workspace entry gating (browser row taps)

    func testOpenEntryIgnoresNonDocumentAndUnavailableRows() async {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                workspace: ShellFixtures.workspace(entries: [
                    ShellFixtures.entry("folder", kind: .directory),
                    ShellFixtures.entry("img.png", kind: .image),
                    ShellFixtures.entry("syncing.md", availability: .downloading),
                    ShellFixtures.entry("post.md"),
                ])
            ),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()
        let entries = scene.sceneWorkspaceEntries

        scene.openEntry(entries[0]) // directory
        scene.openEntry(entries[1]) // image
        scene.openEntry(entries[2]) // downloading
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(facade.openedURLs.isEmpty)

        scene.openEntry(entries[3]) // markdown, available
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(facade.openedURLs.count, 1)
        XCTAssertEqual(facade.openedURLs.first?.scope, .singleFile)
        XCTAssertEqual(facade.openedURLs.first?.url.lastPathComponent, "post.md")
        XCTAssertEqual(scene.selectedEntryID, entries[3].id)
    }

    func testNewFileTargetPrefersSelectedDirectoryThenParentThenRoot() {
        let directory = ShellFixtures.entry("posts", kind: .directory)
        let file = ShellFixtures.entry("posts/a.md")
        let rootFile = ShellFixtures.entry("top.md")
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                workspace: ShellFixtures.workspace(entries: [directory, file, rootFile])
            ),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        // Nothing selected → parent of first top-level entry → workspace root.
        XCTAssertEqual(scene.newFileTarget?.relativePath, "")

        scene.selectedEntryID = directory.id
        XCTAssertEqual(scene.newFileTarget?.relativePath, "posts")

        scene.selectedEntryID = file.id
        XCTAssertEqual(scene.newFileTarget?.relativePath, "posts")

        scene.selectedEntryID = rootFile.id
        XCTAssertEqual(scene.newFileTarget?.relativePath, "")
    }

    func testNewFileTargetNilWithoutWorkspace() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        XCTAssertNil(scene.newFileTarget)
    }

    // MARK: Facade delegation — shell never touches persistence itself

    func testSaveDelegatesToFacadeAndSurfacesErrors() async {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        scene.saveCurrentDocument()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(facade.saveCalls, 1)
        XCTAssertNil(scene.presentedError)

        // An unavailable document surfaces a user-facing error, not silence.
        let emptyFacade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let emptyScene = IOSShellSceneState(facade: emptyFacade)
        emptyScene.startObserving()
        emptyScene.saveCurrentDocument()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertNotNil(emptyScene.presentedError)
    }

    func testConflictReloadDelegatesToFacade() async {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: ShellFixtures.storedDocument(
                    state: .conflict(accessGeneration: 2, recovery: nil)
                )
            ),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()

        scene.resolveExternal(.reload)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(facade.resolvedExternal.count, 1)
    }

    /// Scene state must stay scene-scoped: two scene states over the same
    /// facade carry independent navigation/selection/presentation state.
    func testSceneStateIsNotAppGlobal() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(document: ShellFixtures.storedDocument()),
            capabilities: IOSSceneCapabilities(
                editor: FakeEditorBinding(), documents: nil, workspace: nil,
                preview: nil, assets: nil
            )
        )
        let first = IOSShellSceneState(facade: facade)
        let second = IOSShellSceneState(facade: facade)
        first.startObserving()
        second.startObserving()

        first.navigateToDocument()
        first.present(.frontmatter)
        first.selectedEntryID = UUID()

        XCTAssertEqual(first.navigationPath, [.document])
        XCTAssertEqual(first.presentation, .frontmatter)
        XCTAssertTrue(second.navigationPath.isEmpty)
        XCTAssertNil(second.presentation)
        XCTAssertNil(second.selectedEntryID)
    }
}
