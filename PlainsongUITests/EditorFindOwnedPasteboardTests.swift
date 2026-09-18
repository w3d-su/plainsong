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

    func testOwnedContentsRestoreOriginallyEmptyPasteboard() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let owner = EditorFindOwnedPasteboard(pasteboard: pasteboard)

        try owner.writeString("test-owned")
        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)

        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
        XCTAssertTrue((pasteboard.types ?? []).isEmpty)
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

    func testIdenticalOwnedBytesAtNewGenerationAreNeverAdopted() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, expectedChangeCount in
            let testWrite = EditorFindOwnedPasteboard.writeObjects(
                objects,
                to: pasteboard,
                ifChangeCountIs: expectedChangeCount
            )
            let republishedItems = (pasteboard.pasteboardItems ?? []).map { sourceItem in
                let clone = NSPasteboardItem()
                for type in sourceItem.types {
                    let data = sourceItem.data(forType: type)
                    XCTAssertNotNil(data)
                    if let data {
                        XCTAssertTrue(clone.setData(data, forType: type))
                    }
                }
                return clone
            }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects(republishedItems))
            return testWrite
        }

        XCTAssertThrowsError(try owner.writeString("test-owned")) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .ownedContentsReadbackMismatch = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(
            try owner.restoreIfStillOwned(),
            .externalChangePreserved
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "test-owned"
        )
    }

    func testFailedRestoreRetainsOwnershipForPostTerminationRetry() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var writeAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, expectedChangeCount in
            writeAttempt += 1
            if writeAttempt == 2 {
                return .boundaryMismatch
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
        XCTAssertTrue(owner.hasPendingRestoration)

        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
        XCTAssertEqual(writeAttempt, 3)
    }

    func testFailedRestoreAfterOwnedClearRetainsPostTerminationRetry() throws {
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
                return .attempted(
                    didWrite: false,
                    ownedChangeCount: pasteboard.clearContents()
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
        XCTAssertTrue(owner.hasPendingRestoration)
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)

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
        ) { pasteboard, _, expectedChangeCount in
            guard pasteboard.changeCount == expectedChangeCount else {
                return .boundaryMismatch
            }
            let ownedChangeCount = pasteboard.clearContents()
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("external", forType: .string))
            return .attempted(
                didWrite: false,
                ownedChangeCount: ownedChangeCount
            )
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

    func testFalseWriteResultWithExactOwnedGenerationRetainsRestoration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        var writeAttempt = 0
        let owner = EditorFindOwnedPasteboard(
            pasteboard: pasteboard
        ) { pasteboard, objects, expectedChangeCount in
            writeAttempt += 1
            if writeAttempt == 1 {
                guard pasteboard.changeCount == expectedChangeCount else {
                    return .boundaryMismatch
                }
                let ownedChangeCount = pasteboard.clearContents()
                XCTAssertTrue(pasteboard.writeObjects(objects))
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

        XCTAssertThrowsError(try owner.writeString("test-owned")) { error in
            guard case EditorFindOwnedPasteboard.PasteboardError
                .couldNotWriteOwnedContents = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(owner.hasPendingRestoration)
        XCTAssertEqual(try owner.restoreIfStillOwned(), .restored)
        XCTAssertFalse(owner.hasPendingRestoration)
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: .init("editor-find-owned-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
