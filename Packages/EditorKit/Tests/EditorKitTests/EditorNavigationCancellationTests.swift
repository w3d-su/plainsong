@testable import EditorKit
import Foundation
import XCTest

final class EditorNavigationCancellationTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")
    private let documentB = EditorDocumentIdentity(rawValue: "document-b")

    @MainActor
    func testCancellationSuppressesEveryPendingReasonAndHigherNavigationRunsInOrder() {
        for pendingCase in pendingCases() {
            assertCancellationContract(pendingCase)
        }
    }

    @MainActor
    func testCoordinatorCancellationCleansTasksWhileOlderCancellationIsHarmless() {
        let coordinator = MarkdownTextViewCoordinator(text: .constant("source"), selection: .constant(nil))
        coordinator.observeNavigationCommand(.navigate(request(
            id: 10,
            selection: NSRange(location: 0, length: 0)
        )))
        let retryTask = sleepingTask()
        let deferralTask = sleepingTask()
        coordinator.navigationRetryTask = retryTask
        coordinator.navigationInputDeferralTask = deferralTask

        coordinator.observeNavigationCommand(.cancel(id: 11))

        XCTAssertTrue(retryTask.isCancelled)
        XCTAssertTrue(deferralTask.isCancelled)
        XCTAssertNil(coordinator.navigationRetryTask)
        XCTAssertNil(coordinator.navigationInputDeferralTask)
        XCTAssertNil(coordinator.navigationState.pendingRequest)

        let request12 = request(id: 12, selection: NSRange(location: 1, length: 0))
        coordinator.observeNavigationCommand(.navigate(request12))
        let newerRetryTask = sleepingTask()
        let newerDeferralTask = sleepingTask()
        coordinator.navigationRetryTask = newerRetryTask
        coordinator.navigationInputDeferralTask = newerDeferralTask

        coordinator.observeNavigationCommand(.cancel(id: 11))

        XCTAssertFalse(newerRetryTask.isCancelled)
        XCTAssertFalse(newerDeferralTask.isCancelled)
        XCTAssertEqual(coordinator.navigationState.pendingRequest, request12)
        coordinator.cancelPendingNavigationTasks()
        XCTAssertTrue(newerRetryTask.isCancelled)
        XCTAssertTrue(newerDeferralTask.isCancelled)
    }
}

private extension EditorNavigationCancellationTests {
    struct PendingCase {
        let name: String
        let context: EditorNavigationContext
        let reason: EditorNavigationPendingReason
    }

    @MainActor
    final class EffectRecorder {
        private(set) var events: [String] = []

        var effects: EditorNavigationEffects {
            EditorNavigationEffects(
                applySelection: { [self] _ in
                    events.append("selection")
                    return true
                },
                scrollRangeToVisible: { [self] _ in
                    events.append("scroll")
                },
                focusEditor: { [self] in
                    events.append("focus")
                    return true
                }
            )
        }
    }

    @MainActor
    func assertCancellationContract(_ pendingCase: PendingCase) {
        let selection = NSRange(location: 4, length: 3)
        let resolvedContext = readyContext(document: documentA, textLength: 20)
        let request10 = request(id: 10, selection: selection)
        let request12 = request(id: 12, selection: selection)
        let recorder = EffectRecorder()
        var state = EditorNavigationStateMachine()

        XCTAssertEqual(state.observe(.navigate(request10)), .acceptedNavigation, pendingCase.name)
        XCTAssertEqual(state.nextDecision(in: pendingCase.context), .pending(pendingCase.reason), pendingCase.name)
        XCTAssertEqual(state.observe(.cancel(id: 11)), .acceptedCancellation, pendingCase.name)
        XCTAssertEqual(state.lastCancellationID, 11, pendingCase.name)
        XCTAssertEqual(state.highestObservedCommandID, 11, pendingCase.name)
        XCTAssertEqual(state.nextDecision(in: resolvedContext), .noRequest, pendingCase.name)
        XCTAssertTrue(recorder.events.isEmpty, pendingCase.name)

        XCTAssertEqual(state.observe(nil), .ignored, pendingCase.name)
        XCTAssertEqual(state.observe(.navigate(request10)), .ignored, pendingCase.name)
        XCTAssertEqual(state.nextDecision(in: resolvedContext), .noRequest, pendingCase.name)
        XCTAssertTrue(recorder.events.isEmpty, pendingCase.name)

        XCTAssertEqual(state.observe(.navigate(request12)), .acceptedNavigation, pendingCase.name)
        XCTAssertEqual(state.observe(.cancel(id: 11)), .ignored, pendingCase.name)
        XCTAssertEqual(state.pendingRequest, request12, pendingCase.name)
        guard case let .ready(readyRequest) = state.nextDecision(in: resolvedContext) else {
            return XCTFail("Expected higher navigation to be ready for \(pendingCase.name)")
        }
        XCTAssertTrue(recorder.effects.perform(selection: readyRequest.selection), pendingCase.name)
        state.markHandled(readyRequest)

        XCTAssertEqual(recorder.events, ["selection", "scroll", "focus"], pendingCase.name)
        XCTAssertEqual(state.lastHandledRequestID, 12, pendingCase.name)
        XCTAssertNil(state.pendingRequest, pendingCase.name)

        XCTAssertEqual(state.observe(.cancel(id: 13)), .acceptedCancellation, pendingCase.name)
        XCTAssertEqual(recorder.events, ["selection", "scroll", "focus"], pendingCase.name)
        XCTAssertEqual(state.lastHandledRequestID, 12, pendingCase.name)
        XCTAssertNil(state.pendingRequest, pendingCase.name)
    }

    func pendingCases() -> [PendingCase] {
        [
            PendingCase(
                name: "document mismatch",
                context: navigationContext(document: documentB),
                reason: .documentMismatch
            ),
            PendingCase(
                name: "marked text",
                context: navigationContext(hasMarkedText: true),
                reason: .markedText
            ),
            PendingCase(
                name: "text not installed",
                context: navigationContext(isDocumentTextInstalled: false, textLength: 0),
                reason: .documentTextNotInstalled
            ),
            PendingCase(
                name: "off window",
                context: navigationContext(isAttached: false),
                reason: .notAttached
            ),
        ]
    }

    func navigationContext(
        document: EditorDocumentIdentity? = nil,
        isDocumentTextInstalled: Bool = true,
        textLength: Int = 20,
        hasMarkedText: Bool = false,
        isAttached: Bool = true
    ) -> EditorNavigationContext {
        EditorNavigationContext(
            documentIdentity: document ?? documentA,
            isDocumentTextInstalled: isDocumentTextInstalled,
            documentTextUTF16Length: textLength,
            hasMarkedText: hasMarkedText,
            isAttached: isAttached
        )
    }

    func request(id: UInt64, selection: NSRange) -> EditorNavigationRequest {
        EditorNavigationRequest(id: id, documentIdentity: documentA, selection: selection)
    }

    func readyContext(
        document: EditorDocumentIdentity,
        textLength: Int
    ) -> EditorNavigationContext {
        EditorNavigationContext(
            documentIdentity: document,
            isDocumentTextInstalled: true,
            documentTextUTF16Length: textLength,
            hasMarkedText: false,
            isAttached: true
        )
    }

    @MainActor
    func sleepingTask() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {}
        }
    }
}
