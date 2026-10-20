@testable import Plainsong
import XCTest

/// Pure coverage for `JumpBarMenus.relativePath` and `WorkspaceInspector.location` over
/// real temp directories, including a workspace root that is itself a symlink.
@MainActor
final class WorkspaceRelativeLocationTests: XCTestCase {
    private var base: URL!
    private var real: URL!
    private var real2: URL!
    private var link: URL!

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        real = base.appendingPathComponent("real", isDirectory: true)
        real2 = base.appendingPathComponent("real2", isDirectory: true)
        link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("Caf\u{E9}", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: real2, withIntermediateDirectories: true)
        try "a".write(to: real.appendingPathComponent("sub/a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: real.appendingPathComponent("Caf\u{E9}/b.md"), atomically: true, encoding: .utf8)
        try "x".write(to: real2.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    override func tearDown() async throws {
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
        try await super.tearDown()
    }

    private var aMarkdown: URL {
        real.appendingPathComponent("sub/a.md")
    }

    private var bMarkdown: URL {
        real.appendingPathComponent("Caf\u{E9}/b.md")
    }

    private var xMarkdown: URL {
        real2.appendingPathComponent("x.md")
    }

    func testSymlinkedRootMatchesResolvedAndUnresolvedURLs() {
        XCTAssertEqual(
            JumpBarMenus.relativePath(of: aMarkdown, under: link),
            "sub/a.md"
        )
        XCTAssertEqual(
            JumpBarMenus.relativePath(
                of: link.appendingPathComponent("sub/a.md"),
                under: link
            ),
            "sub/a.md"
        )
    }

    func testFolderEqualToRootMapsToEmptyString() {
        XCTAssertEqual(JumpBarMenus.relativePath(of: real, under: link), "")
        XCTAssertEqual(JumpBarMenus.relativePath(of: link, under: link), "")
        XCTAssertEqual(JumpBarMenus.relativePath(of: real, under: real), "")
    }

    func testOutsideRootAndNilRootReturnNil() {
        XCTAssertNil(JumpBarMenus.relativePath(of: xMarkdown, under: real))
        XCTAssertNil(JumpBarMenus.relativePath(of: xMarkdown, under: link))
        XCTAssertNil(JumpBarMenus.relativePath(of: aMarkdown, under: nil))
    }

    func testPrecomposedFolderNameMatchesTheTreeSpelling() {
        // `==` is the same comparison the folder menu's checkmark uses.
        XCTAssertEqual(
            JumpBarMenus.relativePath(of: bMarkdown, under: link),
            "Caf\u{E9}/b.md"
        )
    }

    func testNonSymlinkedRootKeepsRelativePaths() {
        XCTAssertEqual(
            JumpBarMenus.relativePath(of: aMarkdown, under: real),
            "sub/a.md"
        )
    }

    func testInspectorLocationUsesTheLiteralRootName() {
        XCTAssertEqual(
            WorkspaceInspector.location(of: aMarkdown, rootURL: link),
            "link › sub"
        )
        XCTAssertEqual(
            WorkspaceInspector.location(
                of: real.appendingPathComponent("top.md"),
                rootURL: link
            ),
            "link"
        )
        XCTAssertEqual(
            WorkspaceInspector.location(of: aMarkdown, rootURL: real),
            "real › sub"
        )
    }

    func testInspectorLocationFallsBackToAbsolutePathOutsideOrWithoutRoot() {
        let folder = xMarkdown.deletingLastPathComponent().standardizedFileURL
        XCTAssertEqual(
            WorkspaceInspector.location(of: xMarkdown, rootURL: real),
            folder.path(percentEncoded: false)
        )
        XCTAssertEqual(
            WorkspaceInspector.location(of: aMarkdown, rootURL: nil),
            aMarkdown.deletingLastPathComponent().standardizedFileURL
                .path(percentEncoded: false)
        )
    }
}
