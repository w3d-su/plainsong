import Foundation
import WorkspaceCore
import XCTest

final class WorkspacePathIdentityTests: XCTestCase {
    func testByteKeyDoesNotTreatCanonicalEquivalentsAsEqual() {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd)
        XCTAssertNotEqual(WorkspacePathByteKey(nfc), WorkspacePathByteKey(nfd))
        XCTAssertEqual(Set([WorkspacePathByteKey(nfc), WorkspacePathByteKey(nfd)]).count, 2)
    }

    func testRelativePathRejectsAbsoluteNULTraversalAndEmptyLeaf() {
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: ""), .emptyLeaf)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "."), .emptyLeaf)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "foo//bar.md"), .emptyLeaf)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "foo/./bar.md"), .emptyLeaf)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "/etc/a.md"), .absolutePath)
        XCTAssertNil(WorkspaceRelativePath(spelling: "/etc/a.md"))
        XCTAssertNotEqual(WorkspaceRelativePath(spelling: "/etc/a.md")?.spelling, "etc/a.md")
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "foo/../../etc/passwd"), .parentTraversal)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "a\u{0}b.md"), .nulByte)
    }

    func testRelativePathPreservesDistinctUnicodeSpellings() {
        let nfc = WorkspaceRelativePath(spelling: "caf\u{00E9}.md")
        let nfd = WorkspaceRelativePath(spelling: "cafe\u{0301}.md")
        XCTAssertEqual(nfc?.spelling, "caf\u{00E9}.md")
        XCTAssertEqual(nfd?.spelling, "cafe\u{0301}.md")
        XCTAssertNotEqual(nfc, nfd)
    }

    func testRootMarkerIsNotAnEmptyLeafPath() {
        XCTAssertNil(WorkspaceTreeLocation.file(spelling: ""))
        XCTAssertEqual(WorkspaceTreeLocation.root.relativeSpelling, nil)
        XCTAssertEqual(WorkspaceTreeLocation.file(spelling: "notes.md")?.relativeSpelling, "notes.md")
    }

    func testTreeImageKindIncludesFormatsOutsideThePreviewRasterAllowlist() {
        XCTAssertEqual(kind("icon.svg"), .image)
        XCTAssertEqual(kind("photo.heic"), .image)
        XCTAssertEqual(kind("scan.tiff"), .image)
        XCTAssertEqual(kind("picture.png"), .image)
        XCTAssertEqual(kind("notes.txt"), .other)
        XCTAssertEqual(kind("post.md"), .markdown)
        XCTAssertEqual(kind("page.mdx"), .mdx)
        XCTAssertEqual(
            WorkspaceFileKind(url: URL(fileURLWithPath: "/synthetic/folder.md"), isDirectory: true),
            .directory
        )
    }

    private func kind(_ name: String) -> WorkspaceFileKind {
        WorkspaceFileKind(url: URL(fileURLWithPath: "/synthetic/\(name)"), isDirectory: false)
    }
}
