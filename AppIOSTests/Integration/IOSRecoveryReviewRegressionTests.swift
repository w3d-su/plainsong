import Foundation
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecoveryReviewRegressionTests: XCTestCase {
    func testCreateFailureAfterAdoptionExplainsClosedOriginAndAllowsReopenAndRetry() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let originalID = try XCTUnwrap(fixture.controller.handle?.identity)
        let oldGrant = try XCTUnwrap(fixture.controller.currentGrant)
        let record = recoveryRecord()
        let recovery = controller(fixture, record: record)
        recovery.present()
        let presentationID = try XCTUnwrap(recovery.presentationID)
        XCTAssertTrue(recovery.didAppear(presentationID))
        await recovery.select(record.recordID)
        recovery.requestRestore()
        let request = try XCTUnwrap(recovery.pickerRequest)
        // The initial directory snapshot is clear; the provider refuses create
        // only after safe close and destination adoption, as in a late collision.
        fixture.store.createFailure = .access(.alreadyExists)
        let task = try XCTUnwrap(recovery.completePicker(request, urls: [folder]))
        await task.value
        let message = try XCTUnwrap(recovery.errorMessage)
        XCTAssertTrue(message.contains("previous document was safely closed"))
        XCTAssertTrue(message.contains("use Open to reopen"))
        XCTAssertTrue(message.contains("try restoring into another folder"))
        XCTAssertTrue(recovery.isPresented)
        XCTAssertEqual(recovery.detail?.source, record.source)
        XCTAssertEqual(fixture.store.closed, [originalID])
        XCTAssertTrue(fixture.workspace.invalidated.contains(oldGrant.workspaceID))
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.bindingID)
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertNil(fixture.controller.workspaceSnapshot)
        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertEqual(fixture.store.opened.count, 1, "the failed create installs no substitute writer")

        // Follow the displayed route through a fresh grant; no old authority is revived.
        recovery.isPresented = false
        recovery.didDismiss(presentationID)
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        XCTAssertEqual(fixture.controller.handle?.session.text, "original")
        XCTAssertNotEqual(fixture.controller.currentGrant?.workspaceID, oldGrant.workspaceID)
        fixture.store.createFailure = nil
        recovery.present()
        let retryPresentation = try XCTUnwrap(recovery.presentationID)
        XCTAssertTrue(recovery.didAppear(retryPresentation))
        await recovery.select(record.recordID)
        recovery.requestRestore()
        let retry = try XCTUnwrap(recovery.pickerRequest)
        XCTAssertNotEqual(retry.capture.filename, request.capture.filename)
        let retryTask = try XCTUnwrap(recovery.completePicker(retry, urls: [folder]))
        await retryTask.value
        XCTAssertNil(recovery.errorMessage)
        XCTAssertEqual(fixture.controller.handle?.session.text, record.source)
        XCTAssertEqual(recovery.detail?.source, record.source, "the recovery record is never consumed")
        recovery.didDismiss(retryPresentation)
    }

    func testSuccessfulRestoreRefreshesFilesAfterCreateWithoutAWatcherEvent() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let record = recoveryRecord()
        let capture = try fixture.controller.captureRecoveryRestore(record)
        fixture.workspace.directoryPaths = ["existing.md"]
        // The create changes provider contents after the initial collision check.
        // No snapshotChanged event is sent by this test double.
        fixture.store.onOpen = {
            fixture.workspace.directoryPaths.append(capture.filename)
        }
        var observedPaths: [[String]] = []
        let observation = fixture.controller.observe { snapshot in
            if let tree = snapshot.workspace {
                observedPaths.append(tree.entries.map(\.location.relativePath))
            }
        }
        defer { observation.cancel() }
        try await fixture.controller.restoreRecovery(capture, in: folder,
                                                     loadRecord: { _ in record }, isCurrent: { true })
        let restored = try XCTUnwrap(fixture.controller.handle)
        let tree = try XCTUnwrap(fixture.controller.snapshot.workspace)
        XCTAssertEqual(tree.workspaceID, restored.location.workspaceID)
        XCTAssertEqual(tree.accessGeneration, restored.location.accessGeneration)
        XCTAssertEqual(tree.entries.map(\.location.relativePath), ["existing.md", capture.filename])
        XCTAssertEqual(observedPaths.last, ["existing.md", capture.filename], "Files must receive the post-create tree")
        XCTAssertEqual(restored.location.fileURL.deletingLastPathComponent(), folder)
        XCTAssertEqual(restored.session.text, record.source)
        XCTAssertEqual(fixture.controller.admission.active?.documentID, restored.identity)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
    }

    func testSuccessfulRestoreNavigatesOnceOnlyAfterMatchingActualDismissal() async throws {
        let fixture = IOSSceneControllerFixture()
        let record = recoveryRecord()
        var navigations = 0
        let recovery = IOSRecoveryController(list: { IOSRecoveryList(records: [record], corruptNames: []) },
                                             load: { _ in record },
                                             capture: fixture.controller.captureRecoveryRestore,
                                             restore: { _, _, _ in })
        recovery.onRestored = { navigations += 1 }
        recovery.present()
        let first = try XCTUnwrap(recovery.presentationID)
        XCTAssertTrue(recovery.didAppear(first))
        await recovery.select(record.recordID)
        recovery.requestRestore()
        let request = try XCTUnwrap(recovery.pickerRequest)
        let task = try XCTUnwrap(recovery.completePicker(request, urls: [folder]))
        await task.value
        XCTAssertFalse(recovery.isPresented)
        XCTAssertEqual(navigations, 0)
        recovery.didDismiss(UUID())
        XCTAssertEqual(navigations, 0)
        recovery.didDismiss(first)
        XCTAssertEqual(navigations, 1)
        recovery.didDismiss(first)
        XCTAssertEqual(navigations, 1)
        recovery.present()
        let next = try XCTUnwrap(recovery.presentationID)
        XCTAssertNotEqual(next, first)
        recovery.didDismiss(first)
        XCTAssertEqual(recovery.presentationID, next)
        XCTAssertTrue(recovery.isPresented)
        XCTAssertEqual(navigations, 1)
    }

    func testExternalDismissalCancelsPendingRestoreNavigationAcrossProviderDrain() async throws {
        let fixture = IOSSceneControllerFixture()
        let record = recoveryRecord()
        let entered = expectation(description: "restore provider parked")
        let latch = IOSSceneControllerLatch()
        var navigations = 0
        let recovery = IOSRecoveryController(list: { IOSRecoveryList(records: [record], corruptNames: []) },
                                             load: { _ in record },
                                             capture: fixture.controller.captureRecoveryRestore,
                                             restore: { _, _, isCurrent in
                                                 entered.fulfill()
                                                 await latch.wait()
                                                 XCTAssertFalse(isCurrent())
                                                 throw IOSDocumentFailure.sourceChanged
                                             })
        recovery.onRestored = { navigations += 1 }
        recovery.present()
        let first = try XCTUnwrap(recovery.presentationID)
        XCTAssertTrue(recovery.didAppear(first))
        await recovery.select(record.recordID)
        recovery.requestRestore()
        let request = try XCTUnwrap(recovery.pickerRequest)
        let task = try XCTUnwrap(recovery.completePicker(request, urls: [folder]))
        await fulfillment(of: [entered], timeout: 2)
        recovery.dismiss()
        recovery.didDismiss(first)
        latch.release()
        await task.value
        XCTAssertEqual(navigations, 0)
        XCTAssertNil(recovery.errorMessage, "a cancelled provider error cannot change the retired sheet")
        XCTAssertNil(recovery.presentationID)
        recovery.present()
        XCTAssertNotEqual(recovery.presentationID, first)
        XCTAssertFalse(recovery.didAppear(first))
        recovery.didDismiss(first)
        XCTAssertTrue(recovery.isPresented)
    }

    func testEachRestoreUsesOriginalLeafAndANewCollisionProtectedFilename() throws {
        let fixture = IOSSceneControllerFixture()
        let record = recoveryRecord()
        let first = try fixture.controller.captureRecoveryRestore(record)
        let firstFilename = first.filename
        let second = try fixture.controller.captureRecoveryRestore(record)
        XCTAssertTrue(first.filename.hasPrefix("original-Recovered-"))
        XCTAssertTrue(first.filename.hasSuffix(".mdx"))
        XCTAssertEqual(first.filename, firstFilename, "one picker issuance keeps one destination")
        XCTAssertNotEqual(first.filename, second.filename)
        XCTAssertFalse(first.filename.contains("/"))

        let long = renamedRecord(String(repeating: "文🦊", count: 80) + ".mdx", version: 1)
        let longFilename = try fixture.controller.captureRecoveryRestore(long).filename
        XCTAssertLessThanOrEqual(longFilename.utf8.count, 255)
        XCTAssertTrue(longFilename.hasPrefix("文🦊"))
        XCTAssertTrue(longFilename.hasSuffix(".mdx"))

        let controls = renamedRecord("folder/unsafe\n:\\title.mdx", version: 1)
        let safeFilename = try fixture.controller.captureRecoveryRestore(controls).filename
        XCTAssertTrue(safeFilename.hasPrefix("unsafetitle-Recovered-"))
        XCTAssertFalse(safeFilename.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertFalse(safeFilename.contains("\\"))
        XCTAssertFalse(safeFilename.contains(":"))
        XCTAssertTrue(safeFilename.hasSuffix(".mdx"))

        let hostile = renamedRecord("../bad\0name.mdx", version: 1)
        let fallback = try fixture.controller.captureRecoveryRestore(hostile).filename
        XCTAssertTrue(fallback.hasPrefix("Recovered-"))
        XCTAssertNotNil(WorkspaceRelativePath(spelling: fallback))
        XCTAssertFalse(fallback.contains("/"))
    }

    func testRecoveryListGroupsByFilenameAndShowsNewerRevisionFirst() async {
        let fixture = IOSSceneControllerFixture()
        let old = renamedRecord("a.md", version: 1)
        let newer = renamedRecord("a.md", version: 4)
        let last = renamedRecord("z.md", version: 8)
        let recovery = IOSRecoveryController(list: {
            IOSRecoveryList(records: [last, old, newer], corruptNames: [])
        }, load: { _ in old }, capture: fixture.controller.captureRecoveryRestore,
        restore: { _, _, _ in XCTFail("list refresh must not restore") })
        await recovery.refresh()
        XCTAssertEqual(recovery.records.map(\.recordID), [newer.recordID, old.recordID, last.recordID])
    }

    private let folder = URL(fileURLWithPath: "/synthetic/recovered", isDirectory: true)

    private func controller(_ fixture: IOSSceneControllerFixture, record: IOSRecoveryRecord) -> IOSRecoveryController {
        IOSRecoveryController(list: { IOSRecoveryList(records: [record], corruptNames: []) },
                              load: { _ in record }, capture: fixture.controller.captureRecoveryRestore,
                              restore: { capture, folder, isCurrent in
                                  try await fixture.controller.restoreRecovery(capture, in: folder,
                                                                               loadRecord: { _ in record },
                                                                               isCurrent: isCurrent)
                              })
    }

    private func renamedRecord(_ path: String, version: Int) -> IOSRecoveryRecord {
        IOSRecoveryRecord(recordID: UUID(), operationID: UUID(), documentID: UUID(), revisionVersion: version,
                          workspaceID: UUID(), accessGeneration: 1, resourceID: nil,
                          relativePathUTF8: Data(path.utf8), fileURLPath: "/ungranted/\(path)",
                          source: path, baseline: "", reason: .backgroundDeadline)
    }
}
