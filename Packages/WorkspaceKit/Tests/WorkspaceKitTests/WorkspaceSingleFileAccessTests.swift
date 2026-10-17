import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class WorkspaceSingleFileAccessTests: XCTestCase {
    /// A single-file Powerbox grant permits the file, not enumeration of its parent.
    /// Search-only POSIX permissions reproduce that distinction without a panel or grant.
    func testStandaloneFileReadAndWriteDoNotRequireListingParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-single-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let fileURL = root.appendingPathComponent("post.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)

        let listingDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        let listingError = errno
        if listingDescriptor >= 0 { Darwin.close(listingDescriptor) }
        XCTAssertEqual(listingDescriptor, -1, "The fixture must deny reading directory contents")
        XCTAssertEqual(listingError, EACCES)

        let location = try WorkspaceFileSystemLocation(fileURL: fileURL)
        let store = MarkdownFileStore()
        let loaded = try store.loadResult(at: location)
        XCTAssertEqual(loaded.file.text, "# Original\n")

        let outcome = try store.save(
            text: "# Saved\n",
            at: location,
            expecting: .existingContent(loaded.metadata.identity, sha256Digest: loaded.sha256Digest)
        )
        guard case let .committedAndDurable(result) = outcome else {
            return XCTFail("Search-only parent access must preserve durable writes: \(outcome)")
        }
        XCTAssertEqual(result.cleanupState, .none)
        XCTAssertEqual(try store.load(at: location).text, "# Saved\n")
    }
}
