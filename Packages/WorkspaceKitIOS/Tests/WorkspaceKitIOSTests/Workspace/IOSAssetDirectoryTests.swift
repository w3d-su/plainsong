import Foundation
@testable import WorkspaceKitIOS
import XCTest

final class IOSAssetDirectoryTests: XCTestCase {
    func testCustomAssetDirectoryStaysBesideTheDocument() {
        let paths = IOSWorkspacePathAuthority.assetPaths(
            documentRelativePath: "posts/note.md",
            preferredFilename: "shot.png",
            operationID: UUID(),
            assetFolder: "media"
        )
        XCTAssertEqual(paths?.rootRelative, "posts/media/shot.png")
        XCTAssertEqual(paths?.markdownRelative, "media/shot.png")
    }

    func testAssetDirectoryRejectsTraversalAndHiddenNames() {
        XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory("../assets"), "assets")
        XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory("a/b"), "assets")
        XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory(".hidden"), "assets")
        XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory("  images  "), "images")
    }
}
