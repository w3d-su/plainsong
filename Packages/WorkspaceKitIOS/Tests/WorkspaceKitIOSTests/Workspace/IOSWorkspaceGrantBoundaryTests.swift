import Foundation
@testable import WorkspaceKitIOS
import XCTest

final class IOSWorkspaceGrantBoundaryTests: XCTestCase {
    func testAncestorSymlinkCannotReadOrWriteASiblingRoot() async throws {
        let root = try directory("grant")
        let sibling = try directory("sibling")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
        let secret = Data("sibling-secret".utf8)
        try secret.write(to: sibling.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: sibling)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("assets"),
            withDestinationURL: sibling
        )
        try Data("inside".utf8).write(to: root.appendingPathComponent("local.md"))
        let before = try FileManager.default.contentsOfDirectory(at: sibling, includingPropertiesForKeys: nil)
        let port = IOSSystemWorkspaceFilePort(timeoutNanoseconds: 5_000_000_000)

        let local = try await port.readFile(
            url: root.appendingPathComponent("local.md"),
            relativePath: "local.md",
            maximumByteCount: 32,
            root: root
        )
        XCTAssertEqual(local.data, Data("inside".utf8))

        do {
            _ = try await port.readFile(
                url: root.appendingPathComponent("link").appendingPathComponent("secret.md"),
                relativePath: "link/secret.md",
                maximumByteCount: 32,
                root: root
            )
            XCTFail("ancestor symlink returned sibling bytes")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .outsideGrant)
        }

        do {
            _ = try await port.createFile(
                url: root.appendingPathComponent("assets").appendingPathComponent("hero.png"),
                relativePath: "assets/hero.png",
                data: Data([1, 2, 3, 4]),
                root: root
            )
            XCTFail("ancestor symlink accepted a write")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .outsideGrant)
        }

        do {
            try await port.removeIfOwned(
                url: root.appendingPathComponent("link").appendingPathComponent("secret.md"),
                relativePath: "link/secret.md",
                root: root,
                providerIdentity: Data("not-owned".utf8)
            )
            XCTFail("ancestor symlink deleted a sibling file")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertTrue(failure == .outsideGrant || failure == .indeterminate)
        }

        XCTAssertEqual(try Data(contentsOf: sibling.appendingPathComponent("secret.md")), secret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("hero.png").path))
        let after = try FileManager.default.contentsOfDirectory(at: sibling, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(before.map(\.lastPathComponent)), Set(after.map(\.lastPathComponent)))
    }

    func testProductionRemoveWithoutProviderIdentityKeepsTheLeaf() async throws {
        let root = try directory("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hero.png")
        let bytes = Data([3, 3, 3, 3])
        try bytes.write(to: file)
        let port = IOSSystemWorkspaceFilePort(timeoutNanoseconds: 5_000_000_000)
        do {
            try await port.removeIfOwned(
                url: file,
                relativePath: "hero.png",
                root: root,
                providerIdentity: Data("same-size-other-writer".utf8)
            )
            XCTFail("nil provider identity deleted the leaf")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .indeterminate)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func directory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-lane06-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
