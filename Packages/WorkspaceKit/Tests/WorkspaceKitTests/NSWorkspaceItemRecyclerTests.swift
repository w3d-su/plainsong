import Foundation
@testable import WorkspaceKit
import XCTest

final class NSWorkspaceItemRecyclerTests: XCTestCase {
    func testRecycleReportsTheTrashedItemLocation() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("recycled-\(UUID().uuidString).md")
        try Data("body".utf8).write(to: fileURL)
        let request = try WorkspaceItemRecycleRequest(fileURL: fileURL)

        let mapping: [UUID: URL]
        do {
            mapping = try await NSWorkspaceItemRecycler().recycle([request])
        } catch let error as CocoaError where error.code == .featureUnsupported {
            throw XCTSkip("This volume has no Trash.")
        }

        let trashURL = try XCTUnwrap(mapping[request.id])
        addTeardownBlock { try? FileManager.default.removeItem(at: trashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: trashURL), Data("body".utf8))
    }

    func testRecycleThrowsWhenTheReferencedItemIsGone() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("gone.md")
        try Data("body".utf8).write(to: fileURL)
        let request = try WorkspaceItemRecycleRequest(fileURL: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        do {
            _ = try await NSWorkspaceItemRecycler().recycle([request])
            XCTFail("Recycling a removed item must throw.")
        } catch {}
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NSWorkspaceItemRecyclerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
