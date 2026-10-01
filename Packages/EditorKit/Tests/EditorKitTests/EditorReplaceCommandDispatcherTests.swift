import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// R7 delivery: a plain Replace command reaches only the installed editor of the key
/// window, through its responder chain or App's find-chrome fallback, and is dropped
/// before the executor when its installation or planning stamp no longer holds.
@MainActor
final class EditorReplaceCommandDispatcherTests: XCTestCase {
    override func tearDown() {
        EditorSelectionProbe.keyWindowOverrideForTesting = nil
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testResponderChainDeliversToTheKeyWindowEditor() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        let command = try makeCommand(ready, replacement: "ONE")

        let delivery = EditorReplaceCommandDispatcher.send(command)

        guard case .delivered(.replaced) = delivery else {
            return XCTFail("Expected the key-window editor to replace, got \(delivery)")
        }
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView), "ONE two")
        XCTAssertEqual(ready.fixture.model.source, "ONE two")
    }

    func testANonKeyWindowIsNeverReached() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        let command = try makeCommand(ready, replacement: "ONE")
        try keyWindow(of: ready).isDesignatedKey = false

        XCTAssertEqual(EditorReplaceCommandDispatcher.send(command), .notDelivered(.noKeyWindow))
        XCTAssertEqual(
            EditorReplaceCommandDispatcher.sendToKeyWindowEditor(command),
            .notDelivered(.noKeyWindow)
        )
        assertUntouched(ready)
    }

    func testNilKeyWindowOverrideRefusesBeforeAuthorization() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        let checks = AuthorizationCheckCount()
        let command = try makeCommand(
            ready,
            replacement: "ONE",
            authorization: EditorReplaceAuthorization {
                MainActor.assumeIsolated { checks.value += 1 }
                return true
            }
        )
        EditorSelectionProbe.keyWindowOverrideForTesting = { nil }

        XCTAssertNil(EditorReplaceCommandDispatcher.keyWindow)
        XCTAssertEqual(EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp(), .failure(.noKeyWindow))
        XCTAssertEqual(EditorReplaceCommandDispatcher.send(command), .notDelivered(.noKeyWindow))
        XCTAssertEqual(EditorReplaceCommandDispatcher.sendToKeyWindowEditor(command), .notDelivered(.noKeyWindow))
        XCTAssertEqual(checks.value, 0)
        assertUntouched(ready)
    }

    /// Focus in find chrome or the query field: no editor on the responder chain, so App's
    /// fallback reaches the same key window's installed editor explicitly.
    func testFocusOffTheEditorNeedsTheKeyWindowFallback() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        let command = try makeCommand(ready, replacement: "ONE")
        let field = NSTextField(string: "one")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        try XCTUnwrap(ready.fixture.window.contentView).addSubview(field)
        XCTAssertTrue(ready.fixture.window.makeFirstResponder(field))

        XCTAssertEqual(
            EditorReplaceCommandDispatcher.send(command),
            .notDelivered(.noEditorOnResponderChain)
        )
        assertUntouched(ready)

        let delivery = EditorReplaceCommandDispatcher.sendToKeyWindowEditor(command)
        guard case .delivered(.replaced) = delivery else {
            return XCTFail("Expected the fallback to reach the key-window editor, got \(delivery)")
        }
        XCTAssertEqual(ready.fixture.model.source, "ONE two")
    }

    /// A command planned against a background window's editor never mutates it, and the
    /// key window's editor refuses a command whose installation proof is not its own.
    func testABackgroundWindowsCommandCannotReachEitherEditor() async throws {
        let key = try await makeKeyReady(source: "one two", pattern: "one")
        let background = try await makeKeyReady(source: "one three", pattern: "one")
        let backgroundCommand = try makeCommand(background, replacement: "ONE")
        try keyWindow(of: background).isDesignatedKey = false
        EditorSelectionProbe.keyWindowOverrideForTesting = { key.fixture.window }

        XCTAssertEqual(
            EditorReplaceCommandDispatcher.send(backgroundCommand),
            .notDelivered(.editorNotInstalled)
        )
        XCTAssertEqual(
            EditorReplaceCommandDispatcher.sendToKeyWindowEditor(backgroundCommand),
            .notDelivered(.editorNotInstalled)
        )
        assertUntouched(key)
        assertUntouched(background)
    }

    func testAnUnregisteredInstallationIsRefusedBeforeTheExecutor() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        let command = try makeCommand(ready, replacement: "ONE", installations: [])

        XCTAssertEqual(EditorReplaceCommandDispatcher.send(command), .notDelivered(.editorNotInstalled))
        assertUntouched(ready)
    }

    /// Selection moved after planning: the command is dropped before the executor, so it
    /// neither navigates, authorizes, nor opens an undo group.
    func testSelectionChangeAfterPlanningDropsTheCommand() async throws {
        let ready = try await makeKeyReady(source: "one two one", pattern: "one")
        let checks = AuthorizationCheckCount()
        let command = try makeCommand(
            ready,
            replacement: "ONE",
            authorization: EditorReplaceAuthorization {
                MainActor.assumeIsolated { checks.value += 1 }
                return true
            }
        )
        ready.fixture.textView.textSelection = NSRange(location: 8, length: 3)
        let navigationBefore = ready.controller.pendingNavigationCommand

        XCTAssertEqual(EditorReplaceCommandDispatcher.send(command), .notDelivered(.staleEditorStamp))
        XCTAssertEqual(checks.value, 0)
        XCTAssertEqual(ready.controller.pendingNavigationCommand, navigationBefore)
        assertUntouched(ready, selection: NSRange(location: 8, length: 3))
    }

    func testStampRequiresAnInstalledKeyWindowEditor() async throws {
        let ready = try await makeKeyReady(source: "one two", pattern: "one")
        try keyWindow(of: ready).isDesignatedKey = false
        XCTAssertEqual(
            EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp(),
            .failure(.noKeyWindow)
        )
        try keyWindow(of: ready).isDesignatedKey = true
        ready.fixture.window.contentView = NSView()
        XCTAssertEqual(
            EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp(),
            .failure(.noEditorInKeyWindow)
        )
    }

    // MARK: - Helpers

    private func makeKeyReady(
        source: String,
        pattern: String
    ) async throws -> EditorReplaceSingleSupport.Ready {
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: source,
            pattern: pattern,
            makeWindow: { frame in
                ReplaceDispatchKeyWindow(
                    contentRect: frame,
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
            }
        )
        // `MarkdownTextView.makeNSView` stamps every production editor with this identifier.
        ready.fixture.textView.setAccessibilityIdentifier(EditorAccessibility.textViewIdentifier)
        let window = try keyWindow(of: ready)
        window.isDesignatedKey = true
        EditorSelectionProbe.keyWindowOverrideForTesting = { window }
        XCTAssertTrue(window.makeFirstResponder(ready.fixture.textView))
        ready.fixture.textView.undoManager?.removeAllActions()
        return ready
    }

    private func keyWindow(
        of ready: EditorReplaceSingleSupport.Ready
    ) throws -> ReplaceDispatchKeyWindow {
        try XCTUnwrap(ready.fixture.window as? ReplaceDispatchKeyWindow)
    }

    private func makeCommand(
        _ ready: EditorReplaceSingleSupport.Ready,
        replacement: String,
        authorization: EditorReplaceAuthorization = .allowed(),
        installations: Set<EditorDocumentBindingInstallation>? = nil
    ) throws -> EditorReplaceCommand {
        let stamp = try EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp().get()
        let installation = try XCTUnwrap(ready.fixture.coordinator.currentDocumentBindingInstallation)
        return EditorReplaceCommand(
            request: EditorReplaceSingleSupport.request(
                controller: ready.controller,
                session: ready.session,
                replacement: replacement
            ),
            authorization: authorization,
            controller: ready.controller,
            editorStamp: stamp,
            installations: installations ?? [installation]
        )
    }

    private func assertUntouched(
        _ ready: EditorReplaceSingleSupport.Ready,
        selection: NSRange? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let textView = ready.fixture.textView
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: textView),
            ready.fixture.model.source,
            file: file,
            line: line
        )
        XCTAssertEqual(ready.fixture.model.revision, 0, file: file, line: line)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0, file: file, line: line)
        XCTAssertEqual(ready.fixture.model.publications, [], file: file, line: line)
        XCTAssertEqual(
            textView.selectedRange(),
            selection ?? ready.session.currentMatch?.range,
            file: file,
            line: line
        )
        XCTAssertEqual(ready.controller.session, ready.session, file: file, line: line)
        XCTAssertFalse(textView.undoManager?.canUndo == true, file: file, line: line)
    }
}

/// A window whose key status the test designates; see `DesignatedKeyWindow` in AppTests
/// for why a test process cannot rely on `makeKeyAndOrderFront`.
final class ReplaceDispatchKeyWindow: NSWindow {
    var isDesignatedKey = false

    override var isKeyWindow: Bool {
        isDesignatedKey
    }
}

@MainActor
private final class AuthorizationCheckCount {
    var value = 0
}
