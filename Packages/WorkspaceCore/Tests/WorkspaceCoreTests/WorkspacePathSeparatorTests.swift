@testable import WorkspaceCore
import XCTest

/// `/` followed by a combining scalar is one `Character` that is not `"/"`, while the kernel
/// splits the path at the `0x2F` byte.
final class WorkspacePathSeparatorTests: XCTestCase {
    private let combining = "\u{0301}"

    func testSeparatorWithCombiningScalarIsStillASeparator() {
        let path = "a/\(combining)b/c"
        XCTAssertEqual(path.splitOnPathSeparator().map(String.init), ["a", "\(combining)b", "c"])
        XCTAssertTrue("/\(combining)etc".hasLeadingPathSeparator)
        XCTAssertTrue("x/\(combining)".containsPathSeparator)
        XCTAssertFalse("x\(combining)".containsPathSeparator)
        XCTAssertEqual("a//b".splitOnPathSeparator(omittingEmptySubsequences: false).map(String.init), ["a", "", "b"])
    }

    func testRelativePathRejectsHostileFormsHiddenBehindACombiningScalar() {
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "/\(combining)etc"), .absolutePath)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "../\(combining)secret"), .parentTraversal)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "a/\(combining)/../b"), .parentTraversal)
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "a/./\(combining)b"), .emptyLeaf)
        XCTAssertNil(WorkspaceRelativePath.rejection(for: "a/\(combining)b.md"))
    }
}
