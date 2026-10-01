import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// E2 review fixes: the ownership inventory only ever sees a kernel-canonical destination
/// spelling, and export stages below the app-private root only when sandboxed.
extension ExportDestinationOwnershipAppTests {
    /// A missing owned URL (here a context-only owner) cannot be matched by identity, only by
    /// path. A firmlink spelling of it (`/System/Volumes/Data/…`) passes
    /// `AT_SYMLINK_NOFOLLOW_ANY`, so the writer proves the parent's canonical spelling and refuses
    /// the alias before the inventory is consulted; the canonical spelling is refused by the
    /// inventory itself.
    func testFirmlinkSpellingOfAnOwnedMissingDestinationIsRefused() throws {
        let fixture = try makeWorkspaceFixture()
        let ownedMissing = fixture.root.appendingPathComponent("owned-export.html", isDirectory: false)
        fixture.appState.detachedSessionURLs.insert(ownedMissing)
        let firmlinkPath = "/System/Volumes/Data\(ownedMissing.path(percentEncoded: false))"
        guard FileManager.default.fileExists(atPath: (firmlinkPath as NSString).deletingLastPathComponent) else {
            throw XCTSkip("The test folder has no firmlink spelling on this volume")
        }
        let firmlinkURL = URL(fileURLWithPath: firmlinkPath, isDirectory: false)
        try assertUnownedControlIsPermitted(fixture)

        XCTAssertEqual(ExportArtifactWriter.inspectLeaf(at: firmlinkURL), .failure(.destinationAlias))
        let outcome = fixture.appState.writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: firmlinkURL,
                kind: .html,
                disposition: .createNew,
                bytes: Data("<p>export</p>".utf8)
            ),
            exportSource: fixture.ownedSession
        )

        XCTAssertEqual(outcome, .notCommitted(.destinationAlias))
        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: ownedMissing),
                exportSource: fixture.ownedSession
            ),
            .refused,
            "the canonical spelling of the owned missing URL is refused by the inventory"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedMissing.path(percentEncoded: false)))
        XCTAssertEqual(try operationSiblings(in: fixture.root), [])
    }

    func testExportAppPrivateRootValidatesInjectedContainerIDAndHomeSuffix() {
        let identifier = "app.plainsong.editor"
        let home = "/Users/example/Library/Containers/\(identifier)/Data"
        let sandboxed = ["APP_SANDBOX_CONTAINER_ID": identifier]
        XCTAssertNil(AppState.exportAppPrivateRoot(environment: [:], homeDirectory: home))
        XCTAssertEqual(
            AppState.exportAppPrivateRoot(environment: sandboxed, homeDirectory: home)?.path(percentEncoded: false),
            home + "/"
        )
        for unexpected in [
            "/Users/example",
            "/Users/example/Library/Containers/other.app/Data",
            "/Users/example/Library/Containers/\(identifier)",
            "Library/Containers/\(identifier)/Data",
        ] {
            XCTAssertNil(
                AppState.exportAppPrivateRoot(environment: sandboxed, homeDirectory: unexpected),
                unexpected
            )
        }
        XCTAssertNil(AppState.exportAppPrivateRoot(environment: ["APP_SANDBOX_CONTAINER_ID": ""], homeDirectory: home))
    }
}
