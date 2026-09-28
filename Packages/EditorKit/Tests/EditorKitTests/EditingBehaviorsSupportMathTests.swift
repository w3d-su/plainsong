import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import XCTest

/// Format-menu math commands: MarkdownCore-backed insertion, responder-chain
/// routing, focused-editor menu eligibility, marked-text safety, and undo.
@MainActor
final class EditingBehaviorsSupportMathTests: XCTestCase {
    func testInlineMathCommandInsertsDelimitersAroundSelection() {
        let textView = STTextView(frame: .zero)
        textView.text = "E = mc^2"
        textView.textSelection = NSRange(location: 0, length: 8)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertInlineMath),
            to: textView,
            editingGuard: EditingBehaviorGuard()
        )

        XCTAssertEqual(Self.text(in: textView), "$E = mc^2$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 8))
    }

    func testDisplayMathCommandInsertsBlockOnBlankLine() {
        let textView = STTextView(frame: .zero)
        textView.text = "para\n\n\n\nnext"
        textView.textSelection = NSRange(location: 6, length: 0)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertDisplayMath),
            to: textView,
            editingGuard: EditingBehaviorGuard()
        )

        XCTAssertEqual(Self.text(in: textView), "para\n\n$$\nx\n$$\n\nnext")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 9, length: 1))
    }

    func testMathCommandsRouteThroughResponderChain() {
        let textView = STTextView(frame: .zero)
        let proxy = EditorCommandProxy()
        var commands: [MarkdownEditCommand] = []

        proxy.attach(to: textView, fileKind: .markdown) { command in
            commands.append(command)
        }
        textView.plainsongFormatInsertInlineMath(nil)
        textView.plainsongFormatInsertDisplayMath(nil)

        XCTAssertEqual(commands, [.format(.insertInlineMath), .format(.insertDisplayMath)])
    }

    func testMathCommandEligibilityPublishesOnlyForFocusedEditor() {
        let eligibility = EditorMathCommandEligibility()
        let focused = STTextView(frame: .zero)
        let background = STTextView(frame: .zero)
        let both = MarkdownMathCommandAvailability(
            canInsertInlineMath: true,
            canInsertDisplayMath: true
        )

        XCTAssertFalse(eligibility.availability.canInsertInlineMath)
        XCTAssertFalse(eligibility.availability.canInsertDisplayMath)

        // Results from unfocused editors are dropped.
        eligibility.publish(both, for: background)
        XCTAssertFalse(eligibility.availability.canInsertInlineMath)

        eligibility.activate(focused)
        eligibility.publish(both, for: focused)
        XCTAssertTrue(eligibility.availability.canInsertInlineMath)
        XCTAssertTrue(eligibility.availability.canInsertDisplayMath)

        // A background editor publishing must not steal the menu state.
        eligibility.publish(
            MarkdownMathCommandAvailability(),
            for: background
        )
        XCTAssertTrue(eligibility.availability.canInsertDisplayMath)

        eligibility.deactivate(focused)
        XCTAssertFalse(eligibility.availability.canInsertInlineMath)
        XCTAssertFalse(eligibility.availability.canInsertDisplayMath)
    }

    func testMathCommandAvailabilityMatchesExecutionContext() {
        let textView = STTextView(frame: .zero)
        let editingGuard = EditingBehaviorGuard()

        textView.text = "plain"
        textView.textSelection = NSRange(location: 0, length: 0)
        var availability = EditingBehaviorsSupport.mathCommandAvailability(
            in: textView,
            editingGuard: editingGuard
        )
        XCTAssertTrue(availability.canInsertInlineMath)
        XCTAssertTrue(availability.canInsertDisplayMath)

        // Inside a code span both commands refuse — same answer as apply().
        textView.text = "`code`"
        textView.textSelection = NSRange(location: 3, length: 0)
        availability = EditingBehaviorsSupport.mathCommandAvailability(
            in: textView,
            editingGuard: editingGuard
        )
        XCTAssertFalse(availability.canInsertInlineMath)
        XCTAssertFalse(availability.canInsertDisplayMath)

        // A multi-line selection blocks inline math only.
        textView.text = "a\n\nb"
        textView.textSelection = NSRange(location: 0, length: 4)
        availability = EditingBehaviorsSupport.mathCommandAvailability(
            in: textView,
            editingGuard: editingGuard
        )
        XCTAssertFalse(availability.canInsertInlineMath)
        XCTAssertTrue(availability.canInsertDisplayMath)
    }

    func testMathCommandAvailabilityNoOpsDuringMarkedTextAndGuardedApply() {
        let textView = STTextView(frame: .zero)
        let editingGuard = EditingBehaviorGuard()
        textView.text = "plain"
        textView.textSelection = NSRange(location: 0, length: 0)
        textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        var availability = EditingBehaviorsSupport.mathCommandAvailability(
            in: textView,
            editingGuard: editingGuard
        )
        XCTAssertFalse(availability.canInsertInlineMath)
        XCTAssertFalse(availability.canInsertDisplayMath)

        editingGuard.isApplying = true
        availability = EditingBehaviorsSupport.mathCommandAvailability(
            in: textView,
            editingGuard: editingGuard
        )
        XCTAssertFalse(availability.canInsertInlineMath)
        XCTAssertFalse(availability.canInsertDisplayMath)
    }

    func testCoordinatorPublishesMathEligibilityForFocusedMarkdownTextView() async throws {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "plain",
            selection: NSRange(location: 0, length: 0)
        )
        coordinator.attachMathCommandEligibility(to: textView)
        defer {
            coordinator.detachMathCommandEligibility(from: textView)
            coordinator.detachPasteAndDragHandlers(from: textView)
        }

        textView.firstResponderChangeHandler?(textView, true)
        try await waitForCondition("math eligibility on focus") {
            EditorMathCommandEligibility.shared.availability.canInsertInlineMath
        }
        XCTAssertTrue(EditorMathCommandEligibility.shared.availability.canInsertDisplayMath)

        // Moving the caret inside inline code flips the published state off.
        textView.text = "`code`"
        textView.textSelection = NSRange(location: 3, length: 0)
        coordinator.refreshMathCommandEligibility(for: textView)
        try await waitForCondition("math eligibility inside code") {
            !EditorMathCommandEligibility.shared.availability.canInsertInlineMath
        }
        XCTAssertFalse(EditorMathCommandEligibility.shared.availability.canInsertDisplayMath)

        textView.firstResponderChangeHandler?(textView, false)
        XCTAssertFalse(EditorMathCommandEligibility.shared.availability.canInsertInlineMath)
    }

    func testMathEligibilityRefreshPublishesFalseDuringMarkedText() async throws {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "plain",
            selection: NSRange(location: 0, length: 0)
        )
        coordinator.attachMathCommandEligibility(to: textView)
        defer {
            coordinator.detachMathCommandEligibility(from: textView)
            coordinator.detachPasteAndDragHandlers(from: textView)
        }

        textView.firstResponderChangeHandler?(textView, true)
        try await waitForCondition("math eligibility on focus") {
            EditorMathCommandEligibility.shared.availability.canInsertInlineMath
        }

        textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        coordinator.refreshMathCommandEligibility(for: textView)

        XCTAssertFalse(EditorMathCommandEligibility.shared.availability.canInsertInlineMath)
        XCTAssertFalse(EditorMathCommandEligibility.shared.availability.canInsertDisplayMath)
    }

    func testBackgroundWindowAttachDoesNotOverrideKeyWindowMathEligibility() async throws {
        // XCTest hosts usually cannot make an NSWindow key. The probe window
        // reports the flag production reads; first responders, attach(), and
        // the key notifications stay on real AppKit windows.
        let editorA = makeWindowedEditor(text: "plain", caret: 2)
        let editorB = makeWindowedEditor(text: "`code`", caret: 3)
        defer {
            editorA.coordinator.detachMathCommandEligibility(from: editorA.textView)
            editorB.coordinator.detachMathCommandEligibility(from: editorB.textView)
            editorA.coordinator.detachPasteAndDragHandlers(from: editorA.textView)
            editorB.coordinator.detachPasteAndDragHandlers(from: editorB.textView)
            for window in [editorA.window, editorB.window] {
                window.orderOut(nil)
                window.close()
            }
            EditorMathCommandEligibility.shared.deactivate(editorA.textView)
            EditorMathCommandEligibility.shared.deactivate(editorB.textView)
        }

        editorA.window.reportsKey = true
        XCTAssertTrue(editorA.window.makeFirstResponder(editorA.textView))
        XCTAssertTrue(editorB.window.makeFirstResponder(editorB.textView))

        editorA.coordinator.attachMathCommandEligibility(to: editorA.textView)
        try await waitForCondition("key window math eligibility") {
            EditorMathCommandEligibility.shared.availability.canInsertInlineMath &&
                EditorMathCommandEligibility.shared.availability.canInsertDisplayMath
        }
        XCTAssertTrue(editorA.window.isKeyWindow)
        XCTAssertFalse(editorB.window.isKeyWindow)
        XCTAssertTrue(editorA.window.firstResponder === editorA.textView)
        XCTAssertTrue(editorB.window.firstResponder === editorB.textView)

        editorB.coordinator.attachMathCommandEligibility(to: editorB.textView)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(editorA.window.isKeyWindow)
        XCTAssertTrue(EditorMathCommandEligibility.shared.availability.canInsertInlineMath)
        XCTAssertTrue(EditorMathCommandEligibility.shared.availability.canInsertDisplayMath)

        editorA.window.reportsKey = false
        editorB.window.reportsKey = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: editorA.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: editorB.window)
        try await waitForCondition("background window becomes the math authority") {
            !EditorMathCommandEligibility.shared.availability.canInsertInlineMath &&
                !EditorMathCommandEligibility.shared.availability.canInsertDisplayMath
        }

        editorB.window.reportsKey = false
        editorA.window.reportsKey = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: editorB.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: editorA.window)
        try await waitForCondition("original window regains math eligibility") {
            EditorMathCommandEligibility.shared.availability.canInsertInlineMath &&
                EditorMathCommandEligibility.shared.availability.canInsertDisplayMath
        }
    }

    func testMathEligibilityRefreshSkipsInactiveEditor() {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "plain",
            selection: NSRange(location: 0, length: 0)
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }

        coordinator.refreshMathCommandEligibility(for: textView)

        XCTAssertFalse(coordinator.mathEligibilityInFlight)
        XCTAssertFalse(coordinator.mathEligibilityPending)
    }

    func testMathEligibilityInFlightClearsWhenTextViewIsReleased() async throws {
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant("plain"),
            selection: .constant(NSRange(location: 0, length: 0))
        )
        weak var released: MarkdownSTTextView?
        autoreleasepool {
            let textView = MarkdownSTTextView(frame: .zero)
            textView.textDelegate = coordinator
            textView.text = "plain"
            released = textView
            EditorMathCommandEligibility.shared.activate(textView)
            coordinator.refreshMathCommandEligibility(for: textView)
            XCTAssertTrue(coordinator.mathEligibilityInFlight)
            coordinator.refreshMathCommandEligibility(for: textView)
            XCTAssertTrue(coordinator.mathEligibilityPending)
        }
        XCTAssertNil(released)

        try await waitForCondition("in-flight flag cleared") {
            !coordinator.mathEligibilityInFlight
        }
        XCTAssertFalse(coordinator.mathEligibilityPending)
    }

    func testMathEligibilityAttachIsIdempotentAndFollowsWindowMoves() {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "plain",
            selection: NSRange(location: 0, length: 0)
        )
        let window = MathEligibilityProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            coordinator.detachMathCommandEligibility(from: textView)
            coordinator.detachPasteAndDragHandlers(from: textView)
            window.close()
        }

        // Attached before the view has a window: nothing to observe yet.
        coordinator.attachMathCommandEligibility(to: textView)
        XCTAssertTrue(coordinator.mathEligibilityWindowObservers.isEmpty)

        // Joining a window later installs observers without another update.
        window.contentView = textView
        XCTAssertTrue(coordinator.mathEligibilityObservedWindow === window)
        let observers = coordinator.mathEligibilityWindowObservers.map(ObjectIdentifier.init)
        XCTAssertEqual(observers.count, 2)

        // Repeated representable updates keep the same observers.
        coordinator.attachMathCommandEligibility(to: textView)
        coordinator.attachMathCommandEligibility(to: textView)
        XCTAssertEqual(coordinator.mathEligibilityWindowObservers.map(ObjectIdentifier.init), observers)

        window.contentView = nil
        XCTAssertTrue(coordinator.mathEligibilityWindowObservers.isEmpty)
        XCTAssertNil(coordinator.mathEligibilityObservedWindow)
    }

    func testMathCommandInsideMDXExpressionIsNoOp() {
        let textView = STTextView(frame: .zero)
        textView.text = "value: {a + b}"
        textView.textSelection = NSRange(location: 10, length: 0)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertInlineMath),
            to: textView,
            editingGuard: EditingBehaviorGuard(),
            fileKind: .mdx
        )

        XCTAssertEqual(Self.text(in: textView), "value: {a + b}")
    }
}

@MainActor
private extension EditingBehaviorsSupportMathTests {
    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    func makeWindowedEditor(
        text: String,
        caret: Int
    ) -> (window: MathEligibilityProbeWindow, textView: MarkdownSTTextView, coordinator: MarkdownTextViewCoordinator) {
        let window = MathEligibilityProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let textView = MarkdownSTTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        let selection = NSRange(location: caret, length: 0)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(text),
            selection: .constant(selection)
        )
        window.contentView = textView
        textView.textDelegate = coordinator
        textView.text = text
        textView.textSelection = selection
        coordinator.attachPasteAndDragHandlers(to: textView)
        return (window, textView, coordinator)
    }

    func makeInterceptingTextView(
        text: String,
        selection: NSRange
    ) -> (MarkdownSTTextView, MarkdownTextViewCoordinator) {
        let textView = MarkdownSTTextView(frame: .zero)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(text),
            selection: .constant(selection)
        )
        textView.textDelegate = coordinator
        textView.text = text
        textView.textSelection = selection
        coordinator.attachPasteAndDragHandlers(to: textView)
        return (textView, coordinator)
    }

    func waitForCondition(
        _ description: String,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
        throw MathEligibilityWaitError()
    }
}

private struct MathEligibilityWaitError: Error {}

/// Reports key-window status the test controls. `NSWindow.isKeyWindow` stays
/// false under the XCTest host even after `makeKeyAndOrderFront`.
private final class MathEligibilityProbeWindow: NSWindow {
    var reportsKey = false

    override var isKeyWindow: Bool {
        reportsKey
    }
}
