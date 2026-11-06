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

    func testAssetDirectoryRejectsEmptyControlBidiAndOverlongNames() {
        let refused = [
            "", "   ", ".", "..", "a\\b", "a\u{0}b", "tab\tname", "del\u{7F}", "c\u{85}1",
            "photos\u{202E}gnp.exe", "\u{2066}isolate", String(repeating: "a", count: 256),
            String(repeating: "圖", count: 86),
        ]
        for name in refused {
            XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory(name), "assets", name.debugDescription)
        }
        XCTAssertEqual(
            IOSWorkspacePathAuthority.normalizedAssetDirectory(String(repeating: "a", count: 255)),
            String(repeating: "a", count: 255)
        )
        XCTAssertEqual(IOSWorkspacePathAuthority.normalizedAssetDirectory("圖片 資料"), "圖片 資料")
    }
}
