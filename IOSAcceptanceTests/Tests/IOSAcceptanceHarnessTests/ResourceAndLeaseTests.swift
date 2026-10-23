import Foundation
@testable import IOSAcceptanceHarness
import XCTest

final class ResourceAndLeaseTests: XCTestCase {
    private var lease: FixtureLease?

    override func tearDown() {
        try? lease?.cleanup()
        lease = nil
        super.tearDown()
    }

    func testPinnedManifestMatchesBytesAndPreviewDirectoryIsExact() throws {
        let root = try repositoryRoot()
        let manifest = try String(
            contentsOf: root.appendingPathComponent(
                "IOSAcceptanceTests/Resources/acceptance-resource-manifest.txt"
            ),
            encoding: .utf8
        )
        let records = try ResourcePreflight.validate(root: root, manifest: manifest)
        XCTAssertEqual(records.count, 36)
        XCTAssertTrue(records.allSatisfy { $0.byteCount > 0 && $0.sha256.count == 64 })
        let preview = try ResourcePreflight.validateExactDirectory(
            root: root,
            directory: "App/Resources/preview",
            manifest: manifest
        )
        XCTAssertEqual(preview.count, 25)
        XCTAssertTrue(preview.contains { $0.relativePath == "App/Resources/preview/bundle.js" })
        XCTAssertTrue(preview.contains { $0.relativePath == "App/Resources/preview/mermaid.js" })
    }

    func testHostileEmptyAndTamperedResourcesFailClosed() throws {
        XCTAssertThrowsError(try ResourcePreflight.validate(root: URL(fileURLWithPath: "/tmp"), manifest: "")) {
            XCTAssertEqual($0 as? ResourcePreflightError, .emptyManifest)
        }
        XCTAssertThrowsError(
            try ResourcePreflight.validate(root: URL(fileURLWithPath: "/tmp"), manifest: "../secret")
        ) {
            XCTAssertEqual($0 as? ResourcePreflightError, .hostilePath("../secret"))
        }

        let lease = try makeLease()
        let url = try lease.write(relativePath: "empty.md", data: Data())
        XCTAssertThrowsError(try ResourcePreflight.inspect(root: lease.root, relativePath: "empty.md")) {
            XCTAssertEqual($0 as? ResourcePreflightError, .empty("empty.md"))
        }
        _ = url
        var bytes = Data("hello".utf8)
        _ = try lease.write(relativePath: "note.md", data: bytes)
        let inspected = try ResourcePreflight.inspect(root: lease.root, relativePath: "note.md")
        bytes[0] = 0x58
        try bytes.write(to: lease.root.appendingPathComponent("note.md"))
        XCTAssertThrowsError(
            try ResourcePreflight.validate(
                root: lease.root,
                manifest: "\(inspected.sha256)  note.md\n"
            )
        ) {
            guard case let .hashMismatch(path, _, _) = $0 as? ResourcePreflightError else {
                return XCTFail("expected hash mismatch, got \(String(describing: $0))")
            }
            XCTAssertEqual(path, "note.md")
        }
    }

    func testAncestorSymlinkCannotBeRead() throws {
        let lease = try makeLease()
        let outside = try makeOutsideDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("fixture.md"))
        _ = try linkParent(lease: lease, to: outside)
        let inside = try lease.write(relativePath: "owned/real/fixture.md", data: Data("inside".utf8))
        let record = try ResourcePreflight.inspect(root: lease.root, relativePath: "owned/real/fixture.md")
        XCTAssertEqual(record.byteCount, Data("inside".utf8).count)
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "inside")
        XCTAssertThrowsError(
            try ResourcePreflight.inspect(
                root: lease.root,
                relativePath: "owned/linked-parent/fixture.md"
            )
        ) { error in
            guard case .notRegularFile = error as? ResourcePreflightError else {
                return XCTFail("expected a refused symlink, got \(String(describing: error))")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("fixture.md"), encoding: .utf8),
            "secret"
        )
    }

    func testAncestorSymlinkCannotBeWritten() throws {
        let lease = try makeLease()
        let outside = try makeOutsideDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = try linkParent(lease: lease, to: outside)
        XCTAssertThrowsError(
            try lease.write(relativePath: "owned/linked-parent/fixture.md", data: Data("pwned".utf8))
        ) { error in
            guard case .symlinkEscape = error as? FixtureLeaseError else {
                return XCTFail("expected symlink escape, got \(String(describing: error))")
            }
        }
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        let escaped = try FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil)
        XCTAssertTrue(escaped.isEmpty)
    }

    func testSymlinkResourceIsNotFollowed() throws {
        let lease = try makeLease()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainsong-ios-acceptance-outside-\(UUID().uuidString)"
        )
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: lease.root.appendingPathComponent("link.md"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try ResourcePreflight.inspect(root: lease.root, relativePath: "link.md"))
    }

    func testLeaseCleanupRemovesOnlyItsOwnRoot() throws {
        let parent = FileManager.default.temporaryDirectory
        let sibling = parent.appendingPathComponent("plainsong-user-recents-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let lease = try makeLease()
        let owned = try lease.write(relativePath: "notes/post.md", data: Data("合成".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertThrowsError(try lease.write(relativePath: "../escape.md", data: Data("no".utf8))) {
            XCTAssertEqual($0 as? FixtureLeaseError, .hostilePath("../escape.md"))
        }
        try lease.cleanup()
        try lease.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.root.path))
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep")

        let foreign = parent.appendingPathComponent("plainsong-ios-acceptance-foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: foreign) }
        XCTAssertThrowsError(try FixtureLease.removeIfOwned(root: foreign, token: UUID())) {
            XCTAssertEqual($0 as? FixtureLeaseError, .missingOwnership)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    private func makeLease() throws -> FixtureLease {
        let lease = try FixtureLease()
        self.lease = lease
        return lease
    }

    private func makeOutsideDirectory() throws -> URL {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainsong-ios-acceptance-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        return outside
    }

    private func linkParent(lease: FixtureLease, to outside: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: lease.root.appendingPathComponent("owned"),
            withIntermediateDirectories: false
        )
        let link = lease.root.appendingPathComponent("owned/linked-parent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        return link
    }

    private func repositoryRoot() throws -> URL {
        try XCTUnwrap(AcceptanceRepository.root(startingAt: URL(fileURLWithPath: #filePath)))
    }
}
