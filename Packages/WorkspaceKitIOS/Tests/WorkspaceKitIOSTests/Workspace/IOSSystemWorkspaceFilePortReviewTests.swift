import Foundation
@testable import WorkspaceKitIOS
import XCTest

final class IOSSystemWorkspaceFilePortReviewTests: XCTestCase {
    private let port = IOSSystemWorkspaceFilePort(timeoutNanoseconds: 5_000_000_000)

    func testMetadataReportsALinkInsideTheRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("real.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.md"),
            withDestinationURL: root.appendingPathComponent("real.md")
        )
        let alias = try await port.metadata(
            url: root.appendingPathComponent("alias.md"), relativePath: "alias.md", root: root
        )
        XCTAssertTrue(alias.isSymlink)
        let real = try await port.metadata(
            url: root.appendingPathComponent("real.md"), relativePath: "real.md", root: root
        )
        XCTAssertFalse(real.isSymlink)
        let rootItem = try await port.metadata(url: root, relativePath: "", root: root)
        XCTAssertFalse(rootItem.isSymlink)
    }

    func testCreateDoesNotFollowADanglingLinkOutOfTheRoot() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appendingPathComponent("planted.md")
        // `fileExists` follows the link and reports false, so the existence check passes.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("new.md"), withDestinationURL: target
        )
        do {
            _ = try await port.createFile(
                url: root.appendingPathComponent("new.md"),
                relativePath: "new.md",
                data: Data("draft".utf8),
                root: root
            )
            XCTFail("create followed a link out of the grant")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .alreadyExists)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCreateWritesANewLeafAndRefusesAnExistingOne() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new.md")
        let item = try await port.createFile(url: url, relativePath: "new.md", data: Data("draft".utf8), root: root)
        XCTAssertEqual(item.fileSize, 5)
        XCTAssertEqual(try Data(contentsOf: url), Data("draft".utf8))
        do {
            _ = try await port.createFile(url: url, relativePath: "new.md", data: Data("other".utf8), root: root)
            XCTFail("create overwrote an existing file")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .alreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("draft".utf8))
    }

    func testMissingItemIsNotReportedAsOutsideTheGrant() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await port.metadata(
                url: root.appendingPathComponent("gone.md"), relativePath: "gone.md", root: root
            )
            XCTFail("metadata of a missing file succeeded")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .notFound)
        }
    }

    func testReadIsBoundedByTheByteLimit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.md")
        try Data("12345678".utf8).write(to: url)
        let exact = try await port.readFile(url: url, relativePath: "note.md", maximumByteCount: 8, root: root)
        XCTAssertEqual(exact.data.count, 8)
        do {
            _ = try await port.readFile(url: url, relativePath: "note.md", maximumByteCount: 7, root: root)
            XCTFail("oversized read returned bytes")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .tooLarge)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-review-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
