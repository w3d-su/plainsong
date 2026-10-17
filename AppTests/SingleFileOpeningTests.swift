import Darwin
import Foundation
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class SingleFileOpeningTests: XCTestCase {
    func testOpenAndSaveSingleFileWithoutParentDirectoryReadPermission() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainsongSingleFileOpening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "SingleFileOpeningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fileURL = root.appendingPathComponent("post.md")
        try "# Original\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)
        let listingDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        if listingDescriptor >= 0 { Darwin.close(listingDescriptor) }
        XCTAssertEqual(listingDescriptor, -1, "The fixture must deny reading directory contents")

        let state = AppState(
            workspaceMutationOperationRecoveryStore: TransientMutationOperationStore(),
            workspaceMutationTextRecoveryStore: TransientMutationTextStore(),
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        defer { state.closeWorkspace() }
        try state.open(url: fileURL, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertTrue(state.hasOpenDocument)
        XCTAssertNil(state.workspaceRootURL)
        XCTAssertNil(state.presentedError)
        XCTAssertEqual(state.currentDocument.text, "# Original\n")
        XCTAssertNotNil(state.editorImageAssetDocumentAuthorities[ObjectIdentifier(state.currentDocument)])

        state.replaceDocumentText("# Saved\n")
        state.cancelAutosave(for: state.currentDocument)
        try state.saveCurrentDocument()

        XCTAssertFalse(state.currentDocument.isDirty)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Saved\n")
    }
}
