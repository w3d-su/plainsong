import Foundation
import XCTest

final class WorkspaceFixtureEventSettleTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFixtureEventSettleTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSettleSeesItsSentinelRemovedAndLeavesTheFixtureAsItWas() throws {
        let root = try makeRoot()
        try "fixture".write(to: root.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)

        XCTAssertTrue(WorkspaceFixtureEventSettle.settle(root: root), "the sentinel's removal was never delivered")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["post.md"])
    }

    func testSettleCanRunAgainAfterLaterFixtureWrites() throws {
        let root = try makeRoot()
        try "fixture".write(to: root.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(WorkspaceFixtureEventSettle.settle(root: root))
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("asset.png"))

        XCTAssertTrue(WorkspaceFixtureEventSettle.settle(root: root))

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["asset.png", "post.md"]
        )
    }

    func testSettleReportsFailureWhenTheSentinelCannotBeMade() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFixtureEventSettleTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertFalse(WorkspaceFixtureEventSettle.settle(root: missing))

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
