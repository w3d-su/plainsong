import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R8: every replacement-row state is user-visible text (never color alone), with exactly one
/// presentation per plain PR D–G result value.
final class EditorReplaceStatusTextTests: XCTestCase {
    private func plan(_ source: String, query: String, replacement: String) throws -> EditorReplaceBatchPlan {
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: query))
        return try EditorReplacePlanner.planBatch(session: session, source: source, replacement: replacement).get()
    }

    func testReplaceAllResultsPresentNoChangesChangedOfTotalCancelAndOverflow() throws {
        let identical = try plan("hit hit", query: "hit", replacement: "hit")
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: .delivered(.noChanges(identical))),
            EditorReplaceStatus(kind: .result, text: "No changes")
        )
        // Smart case: the lowercase query also matches `HIT`, which is literally identical.
        let changed = try plan("hit HIT hit", query: "hit", replacement: "HIT")
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: .delivered(.replaced(changed))),
            EditorReplaceStatus(kind: .result, text: "Changed 2 of 3 matches")
        )
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: .cancelled),
            EditorReplaceStatus(kind: .result, text: "Replace All cancelled"),
            "explicit Cancel is distinct from every supersession"
        )
        XCTAssertNotEqual(
            EditorReplaceStatusText.status(for: .superseded),
            EditorReplaceStatusText.status(for: .cancelled)
        )
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: .invalidPlan(.truncatedSession)),
            EditorReplaceStatus(kind: .overflow, text: "More than 10,000 matches; narrow the search.")
        )
        XCTAssertEqual(
            EditorReplaceStatusText.status(
                for: EditorReplaceBatchCommandResult.delivered(.refused(.invalidPlan(.truncatedSession)))
            )?.kind,
            .overflow
        )
    }

    func testProgressAndApplyingTextIsSpokenText() {
        XCTAssertNil(EditorReplaceStatusText.progress(.idle))
        XCTAssertEqual(EditorReplaceStatusText.progress(.preparing(completed: 64, total: 250)), "Preparing 64 / 250")
        XCTAssertEqual(EditorReplaceStatusText.progress(.applying), "Applying…")
    }

    func testEveryAuthorizationRefusalIsABlockedSentenceAndTheInspectionWindowIsTransient() {
        let reasons: [EditorReplaceAuthorizationRefusal] = [
            .notCurrentSession, .authoritySuperseded, .externalObservationPending,
            .externalChangeAwaitingChoice, .externalResolutionSuspended, .externalResolutionInFlight,
            .liveEditorConvergencePending, .indeterminateWriteQuarantine, .workspaceMutationWriteFence,
            .indeterminateWorkspaceMutation, .detachedRecoveryAuthority, .pendingEditorSource,
        ]
        for reason in reasons {
            let single = EditorReplaceStatusText.status(for: EditorReplaceCommandResult.refused(reason))
            let batch = EditorReplaceStatusText.status(for: EditorReplaceBatchCommandResult.refused(reason))
            XCTAssertEqual(single?.kind, .blocked, "\(reason)")
            XCTAssertEqual(single, batch, "\(reason): one sentence whichever command refused")
            XCTAssertFalse(single?.text.isEmpty ?? true, "\(reason)")
        }
        let transient = EditorReplaceStatusText.blocked(.externalObservationPending).text
        XCTAssertTrue(transient.contains("try again"), "an autosave's own inspection is momentary: \(transient)")
        XCTAssertFalse(transient.localizedCaseInsensitiveContains("fail"))
    }

    func testMarkedTextHasOneShapeAndOneSentenceForBothCommands() {
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: EditorReplaceCommandResult.markedText),
            EditorReplaceStatusText.status(for: EditorReplaceBatchCommandResult.markedText)
        )
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: EditorReplaceCommandResult.markedText)?.text,
            "Finish text input before replacing"
        )
    }

    func testSingleReplaceNavigationAndCommitLeaveTheCounterToSpeakButIdenticalSaysNoChanges() throws {
        let match = NSRange(location: 0, length: 3)
        XCTAssertNil(EditorReplaceStatusText.status(for: .delivered(.navigatedToCurrentMatch(match))))
        let session = EditorFindSession.search(in: "hit", query: TextSearchQuery(pattern: "hit"))
        let one = try EditorReplacePlanner.planOneMatch(session: session, source: "hit", replacement: "new").get()
        XCTAssertNil(EditorReplaceStatusText.status(for: .delivered(.replaced(one))))
        let continuation = EditorReplaceContinuationPlanning.afterLiteralIdentical(plan: one, session: session)
        XCTAssertEqual(
            EditorReplaceStatusText.status(for: .delivered(.advancedIdentical(continuation)))?.text,
            "No changes"
        )
    }

    func testFieldErrorsCoverLengthAndLineBreaksAndEmptyIsValid() {
        XCTAssertNil(EditorReplaceStatusText.fieldError(EditorReplacePlanning.validateReplacement("")))
        let atLimit = String(repeating: "a", count: EditorReplaceLimits.maximumReplacementUTF16Length)
        XCTAssertNil(EditorReplaceStatusText.fieldError(EditorReplacePlanning.validateReplacement(atLimit)))
        // 129 surrogate pairs = 258 UTF-16 code units, although only 129 characters.
        let overLimit = String(repeating: "🦊", count: 129)
        XCTAssertEqual(
            EditorReplaceStatusText.fieldError(EditorReplacePlanning.validateReplacement(overLimit)),
            "Replacement is longer than 256 characters"
        )
        XCTAssertEqual(
            EditorReplaceStatusText.fieldError(EditorReplacePlanning.validateReplacement("a\nb")),
            "Replacement must be a single line"
        )
        XCTAssertNil(
            EditorReplaceStatusText.fieldError(EditorReplacePlanning.validateReplacement("$1 \\n \\1")),
            "the value is literal: escapes are ordinary characters"
        )
    }
}
