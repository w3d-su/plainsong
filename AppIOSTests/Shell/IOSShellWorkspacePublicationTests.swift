import Combine
import Foundation
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSShellWorkspacePublicationTests: XCTestCase {
    func testTreeOnlyChangePublishesToBrowserWithoutRepublishingChrome() {
        let before = ShellFixtures.entry("before.md")
        let facade = facade(entries: [before])
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()
        var publications = 0
        var chromePublications = 0
        let treeObserver = scene.objectWillChange.sink { publications += 1 }
        let chromeObserver = scene.$chrome.sink { _ in chromePublications += 1 }
        let chromeBefore = chromePublications
        facade
            .emit(ShellFixtures
                .sceneSnapshot(workspace: ShellFixtures.workspace(entries: [ShellFixtures.entry("after.md")])))
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(chromePublications, chromeBefore)
        XCTAssertEqual(scene.sceneWorkspaceEntries.first?.location.relativePath, "after.md")
        withExtendedLifetime((treeObserver, chromeObserver)) {}
    }

    func testRemovalAndAvailabilityRefreshPublishButEquivalentRefreshDoesNot() {
        let before = ShellFixtures.entry("post.md")
        let facade = facade(entries: [before])
        let scene = IOSShellSceneState(facade: facade)
        scene.startObserving()
        var publications = 0
        let observation = scene.$workspaceSnapshot.sink { _ in publications += 1 }
        let baseline = publications
        facade.emit(ShellFixtures.sceneSnapshot(workspace: ShellFixtures.workspace(entries: [before])))
        XCTAssertEqual(publications, baseline)
        let unavailable = IOSWorkspaceEntry(
            id: before.id, location: before.location, kind: before.kind,
            availability: .offline, children: []
        )
        facade.emit(ShellFixtures.sceneSnapshot(workspace: ShellFixtures.workspace(entries: [unavailable])))
        XCTAssertEqual(publications, baseline + 1)
        facade.emit(ShellFixtures.sceneSnapshot(workspace: ShellFixtures.workspace(entries: [])))
        XCTAssertEqual(publications, baseline + 2)
        XCTAssertTrue(scene.sceneWorkspaceEntries.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testEmptyFolderHasNewFileTargetOnlyWithMatchingDirectoryGrant() async {
        let facade = facade(entries: [])
        let grant = ShellFixtures.grant()
        let scene = IOSShellSceneState(
            facade: facade, surfaces: IOSShellFeatureSurfaces(currentGrant: { grant })
        )
        scene.startObserving()
        XCTAssertEqual(scene.newFileTarget?.relativePath, "")
        XCTAssertEqual(scene.newFileTarget?.fileURL, grant.rootURL)
        scene.createDocument()
        for _ in 0 ..< 10 where facade.createdAt.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(facade.createdAt.count, 1)
        XCTAssertEqual(facade.createdAt.first?.workspaceID, grant.workspaceID)
    }

    func testEntriesDoNotAuthorizeAnImplicitParentOrStaleGrant() {
        let facade = facade(entries: [ShellFixtures.entry("post.md")])
        var grant: IOSWorkspaceGrant?
        let scene = IOSShellSceneState(
            facade: facade, surfaces: IOSShellFeatureSurfaces(currentGrant: { grant })
        )
        scene.startObserving()
        XCTAssertNil(scene.newFileTarget)
        grant = ShellFixtures.grant(scope: .singleFile)
        XCTAssertNil(scene.newFileTarget)
        grant = IOSWorkspaceGrant(
            workspaceID: ShellFixtures.workspaceID, rootURL: URL(fileURLWithPath: "/tmp/workspace"),
            accessGeneration: 2, scope: .directory
        )
        XCTAssertNil(scene.newFileTarget)
        grant = IOSWorkspaceGrant(
            workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), rootURL: URL(fileURLWithPath: "/tmp/other"),
            accessGeneration: 1, scope: .directory
        )
        XCTAssertNil(scene.newFileTarget)
    }

    private func facade(entries: [IOSWorkspaceEntry]) -> FakeSceneFacade {
        FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(workspace: ShellFixtures.workspace(entries: entries)),
            capabilities: IOSSceneCapabilities(editor: nil, documents: nil, workspace: nil, preview: nil, assets: nil)
        )
    }
}
