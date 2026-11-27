import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceSearchReadCacheTests: XCTestCase {
    func testRemovingTheOpenDocumentKeepsAPathThatEndsWithSeparatorAndItsName() {
        var cache = IOSWorkspaceSearchReadCache()
        let nested = ShellFixtures.location("notes|a.md")
        let open = ShellFixtures.location("a.md")
        cache.store(.text("nested"), for: nested)
        cache.store(.text("open"), for: open)

        cache.remove(IOSWorkspaceSearchOpenDocument(
            workspaceID: open.workspaceID, relativePath: "a.md", text: "live"
        ))

        XCTAssertNil(cache.load(open))
        XCTAssertEqual(text(cache.load(nested)), "nested")
        XCTAssertEqual(cache.count, 1)
    }

    func testCanonicallyEquivalentPathsAreDifferentFiles() {
        var cache = IOSWorkspaceSearchReadCache()
        let composed = ShellFixtures.location("caf\u{E9}.md")
        let decomposed = ShellFixtures.location("cafe\u{301}.md")
        cache.store(.text("composed"), for: composed)

        XCTAssertNil(cache.load(decomposed))
        cache.store(.text("decomposed"), for: decomposed)
        XCTAssertEqual(text(cache.load(composed)), "composed")
        XCTAssertEqual(text(cache.load(decomposed)), "decomposed")

        cache.remove(IOSWorkspaceSearchOpenDocument(
            workspaceID: decomposed.workspaceID, relativePath: decomposed.relativePath, text: ""
        ))
        XCTAssertEqual(text(cache.load(composed)), "composed")
        XCTAssertNil(cache.load(decomposed))
    }

    private func text(_ load: IOSWorkspaceSearchController.Load?) -> String? {
        if case let .text(text) = load {
            return text
        }
        return nil
    }
}
