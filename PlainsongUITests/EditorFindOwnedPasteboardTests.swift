import AppKit
import XCTest

@MainActor
final class EditorFindOwnedPasteboardTests: XCTestCase {
    func testOwnedContentsRestoreExactOriginalSnapshot() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("before", forType: .string)
        original.setData(Data([0, 1, 2]), forType: .init("example.binary"))
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let expected = EditorFindOwnedPasteboard.snapshot(of: [original])
        let owner = EditorFindOwnedPasteboard(pasteboard: pasteboard)

        try owner.writeString("test-owned")
        XCTAssertTrue(owner.hasPendingRestoration)
        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)

        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(
            EditorFindOwnedPasteboard.snapshot(
                of: pasteboard.pasteboardItems ?? []
            ),
            expected
        )
    }

    func testExternalPasteboardChangeIsNeverOverwritten() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        let owner = EditorFindOwnedPasteboard(pasteboard: pasteboard)
        try owner.writeString("test-owned")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external", forType: .string))

        XCTAssertEqual(
            try owner.restoreIfStillOwned(),
            .externalChangePreserved
        )
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    func testFailedRestoreRetainsOwnershipForPostTerminationRetry() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var writeAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, _ in
            writeAttempt += 1
            if writeAttempt == 2 {
                return false
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects(objects)
        }
        try owner.writeString("test-owned")

        XCTAssertThrowsError(try owner.restoreIfStillOwned()) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotRestoreOriginalContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(owner.hasPendingRestoration)

        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
        XCTAssertEqual(writeAttempt, 3)
    }

    func testFailedOwnedWriteNeverAdoptsExternalContents() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, _, _ in
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("external", forType: .string))
            return false
        }

        XCTAssertThrowsError(try owner.writeString("test-owned")) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotWriteOwnedContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(
            try owner.restoreIfStillOwned(),
            .externalChangePreserved
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    func testFailedRestoreNeverAdoptsOrOverwritesExternalContents() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var writeAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, _ in
            writeAttempt += 1
            pasteboard.clearContents()
            if writeAttempt == 2 {
                XCTAssertTrue(
                    pasteboard.setString("external", forType: .string)
                )
                return false
            }
            return pasteboard.writeObjects(objects)
        }
        try owner.writeString("test-owned")

        XCTAssertThrowsError(try owner.restoreIfStillOwned()) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotRestoreOriginalContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(
            try owner.restoreIfStillOwned(),
            .externalChangePreserved
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
        XCTAssertEqual(writeAttempt, 2)
    }

    func testUnstableOwnedReadbackRetainsInFlightRestorationLease() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var observationAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard,
            observer: { pasteboard in
                observationAttempt += 1
                let before = pasteboard.changeCount
                let snapshot = EditorFindOwnedPasteboard.snapshot(
                    of: pasteboard.pasteboardItems ?? []
                )
                let after = pasteboard.changeCount
                return EditorFindPasteboardObservation(
                    beforeChangeCount: before,
                    snapshot: snapshot,
                    afterChangeCount:
                    observationAttempt == 2 ? after + 1 : after
                )
            }
        )

        XCTAssertThrowsError(try owner.writeString("test-owned")) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .changedDuringRead = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(owner.hasPendingRestoration)

        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    func testUnreadableOriginalSnapshotPreventsAnyMutation() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var didInvokeWriter = false
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard,
            writer: { _, _, _ in
                didInvokeWriter = true
                return true
            },
            observer: { _ in
                throw EditorFindOwnedPasteboard.PasteboardError
                    .couldNotCaptureExactContents
            }
        )

        XCTAssertThrowsError(try owner.writeString("test-owned")) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotCaptureExactContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(didInvokeWriter)
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    func testConditionalWriterPreservesChangeAtMutationBoundary() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        let capturedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("external", forType: .string)
        let ownedItem = NSPasteboardItem()
        ownedItem.setString("test-owned", forType: .string)

        XCTAssertFalse(
            EditorFindOwnedPasteboard.writeObjects(
                [ownedItem],
                to: pasteboard,
                ifChangeCountIs: capturedChangeCount
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: .init("editor-find-owned-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
