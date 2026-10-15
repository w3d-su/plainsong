import Combine
import Foundation
@testable import PlainsongIOS
import XCTest

@MainActor
final class AuditWorkspacePublicationTests: XCTestCase {
    func testTreeOnlyChangePublishesToBrowser() {
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures
                .sceneSnapshot(workspace: ShellFixtures.workspace(entries: [ShellFixtures.entry("before.md")])),
            capabilities: IOSSceneCapabilities(editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil)
        )
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()
        var publications = 0
        let observer = scene.objectWillChange.sink { publications += 1 }
        facade
            .emit(ShellFixtures
                .sceneSnapshot(workspace: ShellFixtures.workspace(entries: [ShellFixtures.entry("after.md")])))
        XCTAssertEqual(scene.sceneWorkspaceEntries.first?.location.relativePath, "after.md")
        XCTAssertGreaterThan(publications, 0, "A tree-only update must invalidate the browser view")
        _ = observer
    }
}
