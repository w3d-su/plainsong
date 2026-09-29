import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
final class EditorReplaceSingleReplaceAppTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.isReleasedWhenClosed = false
            window.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    func testSingleReplacePublishesToDocumentConsumersAndRescansOnce() async throws {
        let source = "a a"
        let hostedSession = try makeHostedSession(source: source)
        let session = hostedSession.session
        let appState = hostedSession.appState
        let hosted = hostedSession.fixture
        let identity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        let controller = appState.editorFindHost.controller
        let findSession = try await preparedFindSession(
            appState: appState,
            controller: controller,
            identity: identity,
            source: source,
            textView: hosted.textView
        )

        let published = PublishedText()
        let changes = session.textChanges(includeCurrent: false)
        let collector = Task { @MainActor in
            for await change in changes {
                published.values.append(change)
            }
        }
        await Task.yield()

        let outcome = hosted.coordinator.performSingleReplace(
            EditorReplaceRequest(
                documentIdentity: identity,
                sourceRevision: controller.documentBinding.revision,
                queryGeneration: controller.queryGeneration,
                session: findSession,
                replacement: "aa"
            ),
            authorization: .allowed(),
            controller: controller,
            in: hosted.textView
        )
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }

        try await assertPublication(
            session: session,
            appState: appState,
            controller: controller,
            published: published
        )
        collector.cancel()
    }

    /// App routes the post-write publication to Find inside the native write. Find's
    /// session observer (App presentation and navigation) must still run only after
    /// the writer-authorized closure returns.
    func testAppRoutedPublicationNotifiesFindObserversAfterTheWrite() async throws {
        let source = "a a"
        let hostedSession = try makeHostedSession(source: source)
        let appState = hostedSession.appState
        let hosted = hostedSession.fixture
        let identity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        let controller = appState.editorFindHost.controller
        let findSession = try await preparedFindSession(
            appState: appState,
            controller: controller,
            identity: identity,
            source: source,
            textView: hosted.textView
        )
        let appObserver = try XCTUnwrap(controller.onSessionDidChange)
        let depths = DepthLog()
        let coordinator = hosted.coordinator
        controller.onSessionDidChange = {
            depths.values.append(coordinator.writerAuthorizedTextMutationDepth)
            appObserver()
        }

        let outcome = coordinator.performSingleReplace(
            EditorReplaceRequest(
                documentIdentity: identity,
                sourceRevision: controller.documentBinding.revision,
                queryGeneration: controller.queryGeneration,
                session: findSession,
                replacement: "aa"
            ),
            authorization: .allowed(),
            controller: controller,
            in: hosted.textView
        )
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(hostedSession.session.version, 1)
        XCTAssertEqual(controller.documentBinding.revision, 1)
        // App's ordinary publication reached Find during the write and was recorded,
        // not scheduled as `.edit`.
        XCTAssertEqual(controller.recordedReplacementPublicationCount, 1)
        try await waitUntil { controller.session?.currentOrdinal == 3 }
        XCTAssertFalse(depths.values.isEmpty)
        XCTAssertEqual(Set(depths.values), [0])
        XCTAssertEqual(controller.replacementScheduleCount, 1)
        XCTAssertEqual(controller.replacementEngineInvocationCount, 1)
        XCTAssertEqual(controller.editScheduleCount, 0)
    }

    private func assertPublication(
        session: DocumentSession,
        appState: AppState,
        controller: EditorFindController,
        published: PublishedText
    ) async throws {
        XCTAssertEqual(session.text, "aa a")
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        if appState.canAutosave(session: session) {
            XCTAssertNotNil(appState.autosaveTask)
        }
        try await waitUntil { published.values.contains { $0.text == "aa a" && $0.version == 1 } }
        XCTAssertEqual(controller.replacementScheduleCount, 1)
        XCTAssertEqual(controller.editScheduleCount, 0)
        XCTAssertEqual(controller.lastScheduleReason, .replacement(resumeUTF16: 2))
        try await waitUntil {
            controller.replacementEngineInvocationCount == 1
                && controller.session?.currentOrdinal == 3
        }
        guard case let .navigate(request)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected non-focus-stealing continuation")
        }
        XCTAssertFalse(request.shouldFocusEditor)
        XCTAssertEqual(request.selection.location, 3)
        guard case let .navigate(publishedCommand)? = appState.editorNavigationCommand else {
            return XCTFail("Expected App to publish the find navigation")
        }
        XCTAssertEqual(publishedCommand.selection, request.selection)
        XCTAssertFalse(publishedCommand.shouldFocusEditor)
    }

    private struct HostedSession {
        let session: DocumentSession
        let appState: AppState
        let fixture: AppFixture
    }

    private func makeHostedSession(source: String) throws -> HostedSession {
        let session = DocumentSession(
            text: source,
            url: URL(fileURLWithPath: "/tmp/plainsong-replace-d-\(UUID().uuidString).md"),
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false
        )
        let identity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        let hosted = try makeAppBackedFixture(
            session: session,
            appState: appState,
            identity: identity
        )
        return HostedSession(session: session, appState: appState, fixture: hosted)
    }

    private func preparedFindSession(
        appState: AppState,
        controller: EditorFindController,
        identity: EditorDocumentIdentity,
        source: String,
        textView: MarkdownSTTextView
    ) async throws -> EditorFindSession {
        appState.ensureEditorFindSessionObserverInstalled()
        controller.debounceNanoseconds = 0
        controller.rebindDocument(
            EditorFindDocumentBinding(
                identity: identity,
                text: source,
                revision: 0
            )
        )
        controller.setQuery(TextSearchQuery(pattern: "a", caseSensitivity: .sensitive))
        try await waitUntil { controller.session?.currentMatch != nil }
        let findSession = try XCTUnwrap(controller.session)
        textView.textSelection = try XCTUnwrap(findSession.currentMatch).range
        return findSession
    }

    private struct AppFixture {
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func makeAppBackedFixture(
        session: DocumentSession,
        appState: AppState,
        identity: EditorDocumentIdentity
    ) throws -> AppFixture {
        let binding = appState.editorDocumentBinding(for: session)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = session.text
        textView.textSelection = NSRange(location: 0, length: 0)
        let representable = MarkdownTextView(
            text: Binding(get: { session.text }, set: { _ in }),
            styledText: nil,
            selection: .constant(NSRange(location: 0, length: 0)),
            showsLineNumbers: false,
            documentIdentity: identity,
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        textView.undoManager?.removeAllActions()
        return AppFixture(textView: textView, coordinator: coordinator)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}

private final class PublishedText: @unchecked Sendable {
    var values: [DocumentTextChange] = []
}

private final class DepthLog {
    var values: [Int] = []
}
