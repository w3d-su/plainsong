import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WorkspaceKit
import XCTest

// MARK: - Fixtures

@MainActor
extension EditorReplaceAuthorizationAppTests {
    /// One §5.6 input, set and cleared through the App state it lives in.
    struct FenceCase {
        let reason: EditorReplaceAuthorizationRefusal
        let set: () -> Void
        let clear: () -> Void
    }

    // swiftlint:disable:next function_body_length
    func section56Fences(_ fixture: AnchoredFixture) throws -> [FenceCase] {
        let appState = fixture.appState
        let session = appState.currentDocument
        let identity = ObjectIdentifier(session)
        let url = try XCTUnwrap(appState.sessionStateURL(for: session))
        let installation = EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
        return [
            FenceCase(
                reason: .externalObservationPending,
                set: { appState.externalDiskInspectionTasks[identity] = fixture.inspectionTask() },
                clear: { appState.externalDiskInspectionTasks[identity] = nil }
            ),
            FenceCase(
                reason: .externalChangeAwaitingChoice,
                set: { appState.pendingExternalTexts[url] = "disk" },
                clear: { appState.pendingExternalTexts[url] = nil }
            ),
            FenceCase(
                reason: .externalChangeAwaitingChoice,
                set: { appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: url) },
                clear: { appState.externalChangePrompt = nil }
            ),
            FenceCase(
                reason: .externalResolutionSuspended,
                set: { appState.deferredExternalChangeResolutions[url] = .reload },
                clear: { appState.deferredExternalChangeResolutions[url] = nil }
            ),
            FenceCase(
                reason: .externalResolutionInFlight,
                set: { appState.externalReloadTasks[identity] = fixture.reloadTask() },
                clear: { appState.externalReloadTasks[identity] = nil }
            ),
            FenceCase(
                reason: .indeterminateWriteQuarantine,
                set: { appState.indeterminateSessionWrites[identity] = Self.indeterminateWrite },
                clear: { appState.indeterminateSessionWrites[identity] = nil }
            ),
            FenceCase(
                reason: .workspaceMutationWriteFence,
                set: { appState.workspaceMutationWriteFences.insert(identity) },
                clear: { appState.workspaceMutationWriteFences.remove(identity) }
            ),
            FenceCase(
                reason: .indeterminateWorkspaceMutation,
                set: { appState.indeterminateWorkspaceMutationSessions.insert(identity) },
                clear: { appState.indeterminateWorkspaceMutationSessions.remove(identity) }
            ),
            FenceCase(
                reason: .detachedRecoveryAuthority,
                set: { appState.detachedSessionURLs.insert(url) },
                clear: { appState.detachedSessionURLs.remove(url) }
            ),
            FenceCase(
                reason: .detachedRecoveryAuthority,
                set: { appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: url) },
                clear: { appState.missingFilePrompt = nil }
            ),
            FenceCase(
                reason: .pendingEditorSource,
                set: { appState.pendingEditorSourceInstallations[installation] = session },
                clear: { appState.pendingEditorSourceInstallations[installation] = nil }
            ),
        ]
    }

    /// Every App transition that must supersede outstanding Replace plans, in an order each
    /// one can run in.
    func authorityTransitions(_ appState: AppState) -> [(String, () -> Void)] {
        appState.editorFindHost.replaceAuthority.observeKeyWindowChangesIfNeeded()
        let window = registered(EditorReplaceKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        ))
        let installation = EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
        return [
            ("bar open", { self.setBarVisible(true, in: appState) }),
            ("focus request", { appState.showOrRefocusEditorFind() }),
            ("focus receipt", { appState.markEditorFindFocusApplied(appState.editorFindHost.ui.focusRequestID) }),
            ("chrome focus", { appState.setEditorFindChromeFocus(.next, inWindowNumber: 7) }),
            ("chrome focus cleared", { appState.clearEditorFindChromeFocus() }),
            ("editor focus", { appState.requestEditorFocus() }),
            ("focus superseded", {
                appState.showOrRefocusEditorFind()
                appState.supersedePendingEditorFindFocus()
            }),
            ("key window", {
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            }),
            ("key window resigned", {
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            }),
            ("installation", { appState.editorBindingInstallations[installation] = appState.currentDocument }),
            ("installation revoked", { appState.editorBindingInstallations[installation] = nil }),
            ("reload replaced content", { appState.notifyEditorFindExternalContentDidReplace() }),
            ("rekey", { appState.notifyEditorFindDocumentIdentityDidRekey() }),
            ("search activation", { appState.notifyEditorFindWorkspaceSearchWillNavigate(to: NSRange()) }),
            ("rebind", { appState.notifyEditorFindDocumentDidSwitch() }),
            ("document switch", { appState.currentDocument = DocumentSession(text: "other") }),
            ("bar close", { self.setBarVisible(false, in: appState) }),
            ("workspace close", { appState.notifyEditorFindWorkspaceDidClose() }),
        ]
    }

    @MainActor
    struct AnchoredFixture {
        let appState: AppState
        let location: WorkspaceFileSystemLocation

        func inspectionTask() -> ExternalDiskInspectionTask {
            let session = appState.currentDocument
            return ExternalDiskInspectionTask(
                token: UUID(),
                session: session,
                canonicalURL: location.fileURL,
                location: location,
                lifecycleGeneration: 0,
                diskEventGeneration: 0,
                sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
                task: Task {}
            )
        }

        func reloadTask() -> ExternalReloadTask {
            let session = appState.currentDocument
            return ExternalReloadTask(
                token: UUID(),
                generation: 0,
                session: session,
                canonicalURL: location.fileURL,
                location: location,
                lifecycleGeneration: 0,
                sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
                diskEventGeneration: 0,
                intent: .reload,
                task: Task {}
            )
        }
    }

    @MainActor
    struct InstalledUntitled {
        let appState: AppState
        let textView: MarkdownSTTextView
        /// Retained: `textDelegate` is weak, as in production where SwiftUI owns it.
        let coordinator: MarkdownTextViewCoordinator
    }

    static var indeterminateWrite: WorkspaceIndeterminateFileWrite {
        WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
    }

    /// A URL-backed current document on a real file (no editor mounted).
    func makeAnchoredFixture() throws -> AnchoredFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorReplaceAuthorizationAppTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: directory)
        let location = try authority.location(relativePath: "post.md")
        try Data("hit one".utf8).write(to: location.fileURL)
        let session = DocumentSession(text: "hit one", url: location.fileURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        return AnchoredFixture(appState: appState, location: location)
    }

    /// An untitled session installed in a real editor through App's production binding, in
    /// a designated key window, with Find open on `pattern` and the first match applied.
    func makeInstalledUntitled(source: String, pattern: String = "a") async throws -> InstalledUntitled {
        let session = DocumentSession(text: source, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let binding = appState.editorDocumentBinding(for: session)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = session.text
        // `MarkdownTextView.makeNSView` stamps every production editor with this identifier.
        textView.setAccessibilityIdentifier(EditorAccessibility.textViewIdentifier)
        let representable = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: .constant(NSRange(location: 0, length: 0)),
            showsLineNumbers: false,
            documentIdentity: nil,
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = registered(EditorReplaceKeyWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        ))
        window.contentView = scrollView
        window.orderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        window.isDesignatedKey = true
        EditorSelectionProbe.keyWindowOverrideForTesting = { window }
        XCTAssertEqual(appState.liveEditorDocumentBindingInstallations(for: session).count, 1)

        setBarVisible(true, in: appState)
        appState.ensureEditorFindSessionObserverInstalled()
        let controller = appState.editorFindHost.controller
        controller.debounceNanoseconds = 0
        controller.rebindDocument(EditorFindDocumentBinding(identity: nil, text: source, revision: 0))
        controller.setQuery(TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive))
        try await waitUntil { controller.session?.currentMatch != nil }
        textView.textSelection = try XCTUnwrap(controller.session?.currentMatch).range
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.undoManager?.removeAllActions()
        return InstalledUntitled(appState: appState, textView: textView, coordinator: coordinator)
    }

    func setBarVisible(_ isVisible: Bool, in appState: AppState) {
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = isVisible
        appState.setEditorFindUI(ui)
    }

    func registered<Window: NSWindow>(_ window: Window) -> Window {
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func waitUntil(
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
