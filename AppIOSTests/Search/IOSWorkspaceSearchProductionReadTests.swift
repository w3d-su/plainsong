import Foundation
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

/// The production folder-search reader: real grant, lease, 512 KB cap, and the same
/// UTF-8 round-trip rule as opening a document.
@MainActor
final class IOSWorkspaceSearchProductionReadTests: XCTestCase {
    func testReaderAppliesTheGrantSizeAndEncodingRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchRead-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# 標題 match\n".utf8).write(to: root.appendingPathComponent("ok.md"))
        try Data(repeating: UInt8(ascii: "a"), count: IOSWorkspaceSearchLimits.maximumFileBytes + 1)
            .write(to: root.appendingPathComponent("big.md"))
        try Data([0xEF, 0xBB, 0xBF] + Array("bom match".utf8)).write(to: root.appendingPathComponent("bom.md"))
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: root.appendingPathComponent("latin.md"))

        let runtime = try IOSProductionComposition
            .makeProduction(recoveryDirectory: root.appendingPathComponent("Recovery"))
        let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
        let access = try XCTUnwrap(controller.workspace as? IOSWorkspaceAccessService)
        let beforeIDs = Set(access.recentItems().map(\.recordID))
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
            for item in access.recentItems() where !beforeIDs.contains(item.recordID) {
                access.removeRecent(recordID: item.recordID)
            }
            if closed {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try await controller.openPickedURL(root, scope: .directory)
        let entries = try XCTUnwrap(controller.snapshot.workspace?.entries)
        func location(_ name: String) throws -> IOSFileLocation {
            try XCTUnwrap(entries.first { $0.location.relativePath == name }?.location)
        }
        func read(_ location: IOSFileLocation) async throws -> String {
            try await IOSProductionComposition.readSearchDocument(location, controller: controller, access: access)
        }

        let text = try await read(location("ok.md"))
        XCTAssertEqual(text, "# 標題 match\n")
        await assertThrows(IOSWorkspaceSearchReadError.tooLarge) { try await read(location("big.md")) }
        await assertThrows(IOSWorkspaceSearchReadError.unsupportedEncoding) { try await read(location("bom.md")) }
        await assertThrows(IOSWorkspaceSearchReadError.unsupportedEncoding) { try await read(location("latin.md")) }

        let ok = try location("ok.md")
        let stale = IOSFileLocation(
            workspaceID: ok.workspaceID,
            accessGeneration: ok.accessGeneration &+ 1,
            relativePath: ok.relativePath,
            fileURL: ok.fileURL,
            resourceID: ok.resourceID
        )
        do {
            _ = try await read(stale)
            XCTFail("A location from another grant generation must not be read")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .grantChanged)
        }
    }

    private func assertThrows(
        _ expected: IOSWorkspaceSearchReadError,
        _ operation: () async throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceSearchReadError, expected, file: file, line: line)
        }
    }
}
