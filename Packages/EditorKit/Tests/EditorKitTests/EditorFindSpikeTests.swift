import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Proves the F0 spike's responder-chain delivery path (sendAction → focused editor).
/// Synthetic events are **not** F0 evidence; owner physical keyboard under ABC/Zhuyin is.
@MainActor
final class EditorFindSpikeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EditorFindSpike.reset()
    }

    override func tearDown() {
        EditorFindSpike.reset()
        super.tearDown()
    }

    func testShowFindSelectorRecordsFireOnFocusedEditor() throws {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = "spike"
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // This window makes an *editor* first responder and key. Left ordered in, AppKit can
        // keep it reachable and pollute the responder chain for every later test.
        // `orderOut`, not `close`: a programmatic NSWindow defaults to release-on-close.
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder === textView)

        XCTAssertEqual(EditorFindSpike.fireCount, 0)
        // Direct selector delivery (same method the responder chain invokes).
        textView.plainsongShowFind(nil)
        XCTAssertEqual(EditorFindSpike.fireCount, 1)
        XCTAssertNotNil(EditorFindSpike.lastFireDate)

        // sendAction with explicit target (menu path uses to: nil in production;
        // unit tests without a full NSApp activation may not walk the key window).
        XCTAssertTrue(
            NSApplication.shared.sendAction(
                #selector(STTextView.plainsongShowFind(_:)),
                to: textView,
                from: nil
            )
        )
        XCTAssertEqual(EditorFindSpike.fireCount, 2)
    }

    func testShowFindNoOpsWithoutFocusedEditorResponder() throws {
        // `NSApplication.shared`, not `NSApp`: the latter is nil until something instantiates
        // the application, so this crashed when run on its own and only passed because an
        // earlier test in the suite had already created it.
        try withNonEditorKeyWindow { _ in
            XCTAssertEqual(EditorFindSpike.fireCount, 0)
            _ = NSApplication.shared.sendAction(
                #selector(STTextView.plainsongShowFind(_:)),
                to: nil,
                from: nil
            )
            XCTAssertEqual(EditorFindSpike.fireCount, 0)
        }
    }

    func testDispatcherRoutesEachCommandToItsEditorSelector() throws {
        // App must not name `STTextView` (agent.md §6.1), so it sends these through
        // `EditorFindCommandDispatcher`. Prove each case reaches the matching hook.
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = "dispatch"
        // Delivery here is to an explicit target, so this editor is never made key — but keep
        // it out of any window so it cannot join an ambient responder chain either.

        var fired: [String] = []
        EditorFindActionHooks.showFind = { fired.append("show") }
        EditorFindActionHooks.findNext = { fired.append("next") }
        EditorFindActionHooks.findPrevious = { fired.append("previous") }
        EditorFindActionHooks.useSelectionForFind = { fired.append("useSelection") }
        defer {
            EditorFindActionHooks.showFind = nil
            EditorFindActionHooks.findNext = nil
            EditorFindActionHooks.findPrevious = nil
            EditorFindActionHooks.useSelectionForFind = nil
        }

        for command in [EditorFindCommand.show, .next, .previous, .useSelection] {
            XCTAssertTrue(
                EditorFindCommandDispatcher.send(command, to: textView),
                "\(command) must be deliverable to the editor"
            )
        }
        XCTAssertEqual(fired, ["show", "next", "previous", "useSelection"])
    }

    func testDispatcherReportsNotDeliveredWithoutAnEditorResponder() throws {
        // This is the signal App's chrome fallback depends on, so the test has to establish
        // that no editor is reachable rather than inherit whatever an earlier test focused.
        var fired: [String] = []
        EditorFindActionHooks.showFind = { fired.append("show") }
        EditorFindActionHooks.findNext = { fired.append("next") }
        EditorFindActionHooks.findPrevious = { fired.append("previous") }
        EditorFindActionHooks.useSelectionForFind = { fired.append("useSelection") }
        defer {
            EditorFindActionHooks.showFind = nil
            EditorFindActionHooks.findNext = nil
            EditorFindActionHooks.findPrevious = nil
            EditorFindActionHooks.useSelectionForFind = nil
        }

        try withNonEditorKeyWindow { _ in
            for command in [EditorFindCommand.show, .next, .previous, .useSelection] {
                XCTAssertNil(
                    NSApplication.shared.target(
                        forAction: EditorFindCommandDispatcher.selector(for: command)
                    ),
                    "precondition: no editor may be reachable on the responder chain"
                )
                XCTAssertFalse(
                    EditorFindCommandDispatcher.send(command, to: nil),
                    "\(command) must report not-delivered when no editor is on the responder path"
                )
            }
            XCTAssertEqual(fired, [], "nothing may fire when delivery reports false")
        }
    }

    /// Runs `body` with a key window whose first responder is deliberately **not** an editor,
    /// so responder-chain outcomes cannot depend on what another test left focused.
    ///
    /// Skips rather than asserts when the runner refuses key/first-responder changes: a
    /// dirty ambient chain would make the result meaningless either way.
    private func withNonEditorKeyWindow(_ body: (NSWindow) throws -> Void) throws {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let decoy = NSTextField(string: "not-an-editor")
        decoy.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        window.contentView?.addSubview(decoy)
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(decoy) else {
            throw XCTSkip("makeFirstResponder(decoy) unavailable in this runner")
        }
        guard NSApplication.shared.target(
            forAction: EditorFindCommandDispatcher.selector(for: .show)
        ) == nil else {
            throw XCTSkip("An editor is still reachable on the ambient responder chain")
        }
        try body(window)
    }
}
