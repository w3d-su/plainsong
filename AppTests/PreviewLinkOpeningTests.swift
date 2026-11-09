import Foundation
@testable import Plainsong
import XCTest

/// The preview sends a link's rendered `href`, which remark percent-encodes. Opening it as a
/// literal path looked for a file named `%E6%96%87%E7%AB%A0.md` and failed with "Could Not
/// Open File" for every link to a name with a space or a non-ASCII character.
@MainActor
final class PreviewLinkOpeningTests: XCTestCase {
    func testRelativePathIsDecodedAndStripsQueryAndFragment() {
        XCTAssertEqual(AppState.previewLinkRelativePath("%E6%96%87%E7%AB%A0.md"), "文章.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("my%20post.md"), "my post.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("../other.md#part"), "../other.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("other.md?version=2#part"), "other.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("C%23%3F.md"), "C#?.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("文章.md"), "文章.md", "unencoded MDX attribute")
        XCTAssertEqual(AppState.previewLinkRelativePath("./a:b.md"), "./a:b.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("posts/%E4%B8%AD.mdx"), "posts/中.mdx")
    }

    func testAnythingButARelativePathIsRefused() {
        let refused = [
            "", "#heading", "?query", "/etc/hosts.md", "//host/share/x.md", "\\\\server\\x.md",
            "file:///tmp/x.md", "mailto:someone@example.com", "x-plainsong:open.md", "a:b.md",
            "%2Fetc%2Fhosts.md", "%zz.md", "%E6%96.md", "%00.md",
        ]
        for href in refused {
            XCTAssertNil(AppState.previewLinkRelativePath(href), href.debugDescription)
        }
    }

    func testClickingAnEncodedLinkOpensTheNamedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewLinkOpeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let post = directory.appendingPathComponent("post.md")
        let target = directory.appendingPathComponent("中文 文章.md")
        try "[中文 文章](%E4%B8%AD%E6%96%87%20%E6%96%87%E7%AB%A0.md)".write(to: post, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        let appState = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.openExternalFile(post)
        XCTAssertEqual(appState.shownSession.fileURL?.standardizedFileURL, post.standardizedFileURL)

        appState.openPreviewLink("%E4%B8%AD%E6%96%87%20%E6%96%87%E7%AB%A0.md#intro")

        XCTAssertNil(appState.presentedError)
        XCTAssertEqual(appState.shownSession.fileURL?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(appState.shownSession.text, "# Target")
    }
}
