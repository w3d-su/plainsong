import AppKit
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesSameMouseEventSettlesFocusWithoutAnotherOpen() async throws {
        try await assertPendingPickFocus(sameEvent: true, requestsFocus: true)
    }

    func testNativeFilesLaterMouseEventCannotResetThePendingFocusFence() async throws {
        try await assertPendingPickFocus(sameEvent: false, requestsFocus: true)
    }

    func testNativeFilesSameMouseEventCannotPromoteANoFocusPick() async throws {
        try await assertPendingPickFocus(sameEvent: true, requestsFocus: false)
    }

    private func assertPendingPickFocus(sameEvent: Bool, requestsFocus: Bool) async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        let editor = try await waitForView(NSTextView.self, in: host.window)
        let list = try await waitForView(NSTableView.self, in: host.window)
        host.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let event = try makePickMouseEvent(window: host.window, number: 11)
        let read = HeldFilesSelectionRead()
        defer { read.release() }
        let deferral = FilesSelectionDeferral()
        deferral.beforeFileRead = { read.holdFirstRead() }
        let focusBefore = state.editorFocusRequestID
        deferral.open(id: bID, requestingEditorFocus: requestsFocus, pickWindow: host.window,
                      pickEvent: event, appState: state) {}
        try await waitUntil("pending file read is held") { read.isHeld }
        // The same mouse event may finish List responder acquisition after the tap.
        // A different event models the user deliberately moving focus while IO waits.
        XCTAssertTrue(host.window.makeFirstResponder(list))
        let reportedEvent: NSEvent = if sameEvent {
            event
        } else {
            try makePickMouseEvent(window: host.window, number: 12)
        }
        deferral.reaffirmPendingMousePick(id: bID, window: host.window, event: reportedEvent)
        read.release()
        try await waitUntil("pending file pick finishes") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md" && deferral.pendingID == nil
        }
        XCTAssertEqual(state.currentDocument.text, "beta")
        XCTAssertEqual(deferral.issued, 1)
        XCTAssertEqual(deferral.openAttempts.filter(\.landed).count, 1)
        let shouldFocus = sameEvent && requestsFocus
        XCTAssertEqual(state.editorFocusRequestID, focusBefore + (shouldFocus ? 1 : 0))
        if !shouldFocus {
            XCTAssertTrue(host.window.firstResponder === list)
        }
    }

    private func makePickMouseEvent(window: NSWindow, number: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: number, clickCount: 1, pressure: 0
        ))
    }
}
