import Foundation
@testable import WorkspaceCore
import XCTest

final class WorkspacePathIdentityTests: XCTestCase {
    func testPreparedPathOrderMatchesFoundationAndByteTies() {
        let ascii = (0 ..< 128).map { "folder/P\(UnicodeScalar($0)!)ost.md" }
        let names = [
            "", "0", "00", "01", "1", "2", "10", "002", "01z", "1A", "1[", "2:3", "10:2",
            "999999999", "1000000000", "0000000000", "18446744073709551616",
            "A2B02.md", "a02b2.md", "a2b10.md", "A2b2.MD",
            "١", "１２", "٠", "é", "e\u{0301}", "Å", "A\u{030a}", "SS", "ß", "文2", "文10", "👩‍💻",
        ]
        let paths = (ascii + names).map { (path: $0, key: WorkspacePathOrder.Key($0)) }
        for first in paths {
            for second in paths {
                let comparison = first.path.compare(second.path, options: [.caseInsensitive, .numeric])
                let expected = comparison == .orderedSame
                    ? first.path.utf8.lexicographicallyPrecedes(second.path.utf8)
                    : comparison == .orderedAscending
                XCTAssertEqual(
                    first.key.isBefore(second.key),
                    expected,
                    "\(first.path.debugDescription), \(second.path.debugDescription)"
                )
            }
        }
    }

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
