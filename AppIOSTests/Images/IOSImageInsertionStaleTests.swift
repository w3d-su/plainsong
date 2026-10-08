import EditorKitIOS
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSImageInsertionStaleTests: XCTestCase {
    func testSwitchingDocumentDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.identity = IOSDocumentIdentity(rawValue: UUID())
            harness.editor.version += 4
        }, .documentChanged)
    }

    func testSameVersionDifferentDocumentRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        }, .documentChanged)
    }

    func testNativeEditDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.version += 1
        }, .sourceChanged)
    }

    func testSelectionABARollsBack() async throws {
        try await expectStageRefusal({ harness in
            let original = harness.editor.selection
            harness.editor.selection = NSRange(location: 0, length: 0)
            harness.editor.selection = original
            harness.editor.selectionGeneration += 2
        }, .selectionChanged)
    }

    func testAccessGenerationChangeDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.accessGeneration += 1
        }, .accessChanged)
    }

    func testComposingDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.hasMarkedText = true
        }, .markedText)
    }

    func testReadOnlyDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.canWrite = false
        }, .readOnly)
    }

    func testLostFocusDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.isFocused = false
        }, .notFocused)
    }

    func testBindingReplacementDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.bindingID = UUID()
        }, .bindingChanged)
    }

    func testMissingSnapshotDuringStageRollsBack() async throws {
        try await expectStageRefusal({ harness in
            harness.editor.returnNilSnapshot = true
        }, .unavailable)
    }

    func testAccessGenerationChangeAfterValidateRollsBack() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseValidate = true
        let task = Task { await harness.insert(context) }
        await harness.writer.validateEntered.wait()
        XCTAssertEqual(harness.editor.submitted.count, 0)
        harness.editor.accessGeneration += 1
        harness.writer.validateRelease.signal()
        await assertRefused(task.value, .accessChanged)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken])
        XCTAssertFalse(harness.probe.events.contains("apply"))
    }

    func testDestinationValidationFailureRollsBack() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.validateFailure = IOSWorkspaceFailure.grantChanged
        let context = try harness.capture()
        await assertFailed(harness.insert(context), .grantChanged)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "rollback"])
    }

    func testStagedWorkspaceReplacementRollsBack() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.workspaceOverride = IOSWorkspaceIdentity(rawValue: UUID())
        let context = try harness.capture()
        await assertFailed(harness.insert(context), .grantChanged)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertFalse(harness.probe.events.contains("apply"))
    }

    func testStagedGenerationMismatchRollsBack() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.generationOverride = 99
        let context = try harness.capture()
        await assertFailed(harness.insert(context), .grantChanged)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken])
    }

    func testURLPrefixIsNotGrantAuthority() async throws {
        let rejected = ImageInsertionHarness(destinationGeneration: 9, editorAccessGeneration: 8)
        XCTAssertNil(rejected.controller.captureContext(
            using: rejected.editor,
            destination: rejected.destination,
            grant: rejected.grant
        ))
        XCTAssertEqual(rejected.writer.calls, [])
        rejected.assertSourceUntouched()

        let accepted = ImageInsertionHarness()
        XCTAssertNotEqual(accepted.destination.fileURL.path, accepted.grant.rootURL.path)
        _ = try await assertInserted(accepted.insert(accepted.capture()))
    }

    func testSingleFileGrantDoesNotSaveOrEdit() {
        let harness = ImageInsertionHarness(scope: .singleFile)
        var requests = 0
        let session = harness.session { requests += 1 }
        XCTAssertNil(session.preparePicker())
        XCTAssertEqual(session.phase, .needsDirectoryGrant)
        session.requestDirectoryGrant()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
        XCTAssertTrue(IOSImageInsertionMessages.needsDirectoryGrant().contains("Nothing was saved"))
    }

    func testComposingOrUnfocusedCaptureDoesNotOpen() {
        let composing = ImageInsertionHarness()
        composing.editor.hasMarkedText = true
        let composingSession = composing.session()
        XCTAssertNil(composingSession.preparePicker())
        XCTAssertEqual(composingSession.phase, .refused(.markedText))
        composing.assertSourceUntouched()

        let idle = ImageInsertionHarness()
        idle.editor.isFocused = false
        let idleSession = idle.session()
        XCTAssertNil(idleSession.preparePicker())
        XCTAssertEqual(idleSession.phase, .refused(.notFocused))
        XCTAssertEqual(idle.writer.calls, [])
        idle.assertSourceUntouched()
    }

    private func expectStageRefusal(
        _ mutate: (ImageInsertionHarness) -> Void,
        _ reason: IOSEditRefusal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        mutate(harness)
        harness.writer.stageRelease.signal()
        await assertRefused(task.value, reason, file: file, line: line)
        harness.assertSourceUntouched(file: file, line: line)
        XCTAssertEqual(harness.writer.rollbackCount, 1, file: file, line: line)
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken], file: file, line: line)
        XCTAssertFalse(harness.probe.events.contains("apply"), file: file, line: line)
        XCTAssertEqual(harness.probe.events.filter { $0 == "rollback" }.count, 1, file: file, line: line)
    }
}
