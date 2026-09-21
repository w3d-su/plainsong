import AppKit
import XCTest

@MainActor
final class EditorFindOwnedPasteboardFailureTests: XCTestCase {
    func testFailedRestoreNeverAdoptsOrOverwritesExternalContents() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var writeAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, expectedChangeCount in
            writeAttempt += 1
            if writeAttempt == 2 {
                guard pasteboard.changeCount == expectedChangeCount else {
                    return .boundaryMismatch
                }
                let ownedChangeCount = pasteboard.clearContents()
                pasteboard.clearContents()
                XCTAssertTrue(
                    pasteboard.setString("external", forType: .string)
                )
                return .attempted(
                    didWrite: false,
                    ownedChangeCount: ownedChangeCount
                )
            }
            return EditorFindOwnedPasteboard.writeObjects(
                objects,
                to: pasteboard,
                ifChangeCountIs: expectedChangeCount
            )
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
                return .boundaryMismatch
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

        XCTAssertEqual(
            EditorFindOwnedPasteboard.writeObjects(
                [ownedItem],
                to: pasteboard,
                ifChangeCountIs: capturedChangeCount
            ),
            .boundaryMismatch
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    func testNilItemsWithAdvertisedTypesFailExactCapture() {
        XCTAssertThrowsError(
            try EditorFindOwnedPasteboard.exactSnapshot(
                of: nil,
                advertisedTypes: [.string]
            )
        ) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotCaptureExactContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNilItemsAndTypesRepresentObservableEmptyPasteboard() throws {
        XCTAssertEqual(
            try EditorFindOwnedPasteboard.exactSnapshot(
                of: nil,
                advertisedTypes: nil
            ),
            []
        )
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: .init("editor-find-owned-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
