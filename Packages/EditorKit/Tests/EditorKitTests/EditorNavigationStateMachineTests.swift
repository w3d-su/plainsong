@testable import EditorKit
import Foundation
import XCTest

final class EditorNavigationStateMachineTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")
    private let documentB = EditorDocumentIdentity(rawValue: "document-b")

    func testPublicModelsPreserveOpaqueIdentityMonotonicIDAndExactRange() {
        let range = NSRange(location: 7, length: 4)
        let request = EditorNavigationRequest(
            id: 42,
            documentIdentity: documentA,
            selection: range
        )

        XCTAssertEqual(documentA.rawValue, "document-a")
        XCTAssertEqual(request.id, 42)
        XCTAssertEqual(request.documentIdentity, documentA)
        XCTAssertEqual(request.selection, range)
    }

    @MainActor
    func testSameDocumentAppliesExactSelectionThenScrollThenFocus() {
        let range = NSRange(location: 9, length: 5)
        let request = request(id: 1, document: documentA, range: range)
        var state = EditorNavigationStateMachine()
        state.observe(.navigate(request))
        var effectsInOrder: [String] = []
        var appliedSelection: NSRange?
        var scrolledRange: NSRange?
        let effects = EditorNavigationEffects(
            applySelection: { selection in
                effectsInOrder.append("selection")
                appliedSelection = selection
                return true
            },
            scrollRangeToVisible: { selection in
                effectsInOrder.append("scroll")
                scrolledRange = selection
            },
            focusEditor: {
                effectsInOrder.append("focus")
                return true
            }
        )

        let decision = state.nextDecision(in: readyContext(document: documentA, textLength: 20))
        guard case let .ready(readyRequest) = decision else {
            return XCTFail("Expected a ready navigation request, got \(decision)")
        }
        XCTAssertTrue(effects.perform(selection: readyRequest.selection))
        state.markHandled(readyRequest)

        XCTAssertEqual(appliedSelection, range)
        XCTAssertEqual(scrolledRange, range)
        XCTAssertEqual(effectsInOrder, ["selection", "scroll", "focus"])
        XCTAssertEqual(state.lastHandledRequestID, 1)
        XCTAssertNil(state.pendingRequest)
    }

    func testWrongDocumentIdentityLeavesRequestPendingWithoutEffects() {
        let request = request(id: 1, document: documentB, range: NSRange(location: 2, length: 3))
        var state = EditorNavigationStateMachine()
        state.observe(.navigate(request))

        XCTAssertEqual(
            state.nextDecision(in: readyContext(document: documentA, textLength: 20)),
            .pending(.documentMismatch)
        )
        XCTAssertEqual(state.pendingRequest, request)
        XCTAssertNil(state.lastHandledRequestID)
    }

    func testSameRequestIDIsIdempotentAfterItIsHandled() {
        let request = request(id: 7, document: documentA, range: NSRange(location: 2, length: 3))
        var state = EditorNavigationStateMachine()
        state.observe(.navigate(request))
        state.markHandled(readyRequest(from: &state, textLength: 20))

        state.observe(.navigate(request))

        XCTAssertEqual(state.nextDecision(in: readyContext(document: documentA, textLength: 20)), .noRequest)
        XCTAssertEqual(state.lastHandledRequestID, 7)
    }

    func testNewIDReplaysTheSameDocumentAndRange() {
        let range = NSRange(location: 4, length: 6)
        var state = EditorNavigationStateMachine()
        let first = request(id: 10, document: documentA, range: range)
        state.observe(.navigate(first))
        state.markHandled(readyRequest(from: &state, textLength: 20))

        let replay = request(id: 11, document: documentA, range: range)
        state.observe(.navigate(replay))

        XCTAssertEqual(
            state.nextDecision(in: readyContext(document: documentA, textLength: 20)),
            .ready(replay)
        )
    }

    func testOlderIDCannotOverwriteANewerHandledRequest() {
        var state = EditorNavigationStateMachine()
        let newer = request(id: 20, document: documentA, range: NSRange(location: 8, length: 2))
        state.observe(.navigate(newer))
        state.markHandled(readyRequest(from: &state, textLength: 20))

        state.observe(.navigate(request(
            id: 19,
            document: documentA,
            range: NSRange(location: 1, length: 1)
        )))

        XCTAssertEqual(state.highestObservedCommandID, 20)
        XCTAssertEqual(state.lastHandledRequestID, 20)
        XCTAssertNil(state.pendingRequest)
    }

    func testNewerPendingRequestSupersedesOlderPendingRequest() {
        var state = EditorNavigationStateMachine()
        let older = request(id: 30, document: documentB, range: NSRange(location: 1, length: 2))
        state.observe(.navigate(older))
        XCTAssertEqual(
            state.nextDecision(in: readyContext(document: documentA, textLength: 20)),
            .pending(.documentMismatch)
        )

        let newer = request(id: 31, document: documentA, range: NSRange(location: 7, length: 3))
        state.observe(.navigate(newer))

        XCTAssertEqual(state.pendingRequest, newer)
        XCTAssertEqual(
            state.nextDecision(in: readyContext(document: documentA, textLength: 20)),
            .ready(newer)
        )
    }

    func testMalformedAndOutOfBoundsRangesAreRejectedWithoutClampingOrRetry() {
        let invalidRanges = [
            NSRange(location: NSNotFound, length: 0),
            NSRange(location: -1, length: 0),
            NSRange(location: 0, length: -1),
            NSRange(location: Int.max - 1, length: 10),
            NSRange(location: 11, length: 0),
            NSRange(location: 9, length: 2),
        ]

        for (index, range) in invalidRanges.enumerated() {
            let id = UInt64(index + 1)
            let request = request(id: id, document: documentA, range: range)
            var state = EditorNavigationStateMachine()
            state.observe(.navigate(request))

            XCTAssertEqual(
                state.nextDecision(in: readyContext(document: documentA, textLength: 10)),
                .rejected(request),
                "Expected rejection for \(range)"
            )
            XCTAssertEqual(state.lastRejectedRequestID, id)
            XCTAssertNil(state.pendingRequest)
            XCTAssertEqual(
                state.nextDecision(in: readyContext(document: documentA, textLength: 10)),
                .noRequest,
                "A rejected request must not retry forever"
            )
        }
    }

    func testPermanentlyMalformedRangeIsRejectedBeforeTargetDocumentIsRendered() {
        let request = request(
            id: 100,
            document: documentB,
            range: NSRange(location: NSNotFound, length: 0)
        )
        var state = EditorNavigationStateMachine()
        state.observe(.navigate(request))
        let unrelatedContext = EditorNavigationContext(
            documentIdentity: documentA,
            isDocumentTextInstalled: false,
            documentTextUTF16Length: 0,
            hasMarkedText: true,
            isAttached: false
        )

        XCTAssertEqual(state.nextDecision(in: unrelatedContext), .rejected(request))
        XCTAssertNil(state.pendingRequest)
        XCTAssertEqual(state.lastRejectedRequestID, 100)
    }

    func testCJKEmojiAndCombiningMarkRangesRemainExactUTF16Selections() {
        let source = "prefix 中文 🧪 e\u{301} suffix"
        let fixtures = ["中文", "🧪", "\u{301}"]
        var state = EditorNavigationStateMachine()

        for (index, fixture) in fixtures.enumerated() {
            let expectedRange = (source as NSString).range(of: fixture)
            let request = request(
                id: UInt64(index + 1),
                document: documentA,
                range: expectedRange
            )
            state.observe(.navigate(request))
            let ready = readyRequest(from: &state, textLength: (source as NSString).length)

            XCTAssertEqual(ready.selection, expectedRange)
            XCTAssertEqual((source as NSString).substring(with: ready.selection), fixture)
            state.markHandled(ready)
        }
    }
}

private extension EditorNavigationStateMachineTests {
    func request(
        id: UInt64,
        document: EditorDocumentIdentity,
        range: NSRange
    ) -> EditorNavigationRequest {
        EditorNavigationRequest(id: id, documentIdentity: document, selection: range)
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

    func readyRequest(
        from state: inout EditorNavigationStateMachine,
        textLength: Int
    ) -> EditorNavigationRequest {
        let decision = state.nextDecision(in: readyContext(document: documentA, textLength: textLength))
        guard case let .ready(request) = decision else {
            XCTFail("Expected ready request, got \(decision)")
            return EditorNavigationRequest(
                id: 0,
                documentIdentity: documentA,
                selection: NSRange(location: 0, length: 0)
            )
        }
        return request
    }
}
