import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import PreviewKit
import SwiftUI
import WebKit
import XCTest

/// Hosted production-path evidence for the Editor Find gates that cannot be closed by
/// AppState-only tests. These tests deliberately do not claim physical keyboard, real IME,
/// or Full Keyboard Access evidence.
@MainActor
final class EditorFindHostedGateTests: XCTestCase {
    func testHostedFindBarSurvivesExternalReloadAndUnmountsAfterMissingFileClose() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "hit one"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)

        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }

        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "hit")

        try await waitUntil("production find field mounts") {
            self.findQueryField(in: host.window) != nil
                && appState.editorFindHost.controller.session?.total == 1
        }

        let post = fixture.root.appendingPathComponent("post.md")
        try "hit one hit two hit three".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()

        try await waitUntil("clean external reload reaches the hosted editor and find counter") {
            appState.currentDocument.text == "hit one hit two hit three"
                && appState.editorFindHost.controller.session?.total == 3
                && self.findQueryField(in: host.window) != nil
        }
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")
        XCTAssertNil(appState.editorFindHost.controller.pendingNavigationCommand)

        try FileManager.default.removeItem(at: post)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("missing-file recovery prompt appears") {
            appState.missingFilePrompt?.fileURL.lastPathComponent == "post.md"
        }

        appState.closeMissingFile()
        try await waitUntil("closing the missing file unmounts the production find field") {
            !appState.hasOpenDocument
                && !appState.editorFindHost.ui.isBarVisible
                && self.findQueryField(in: host.window) == nil
        }
        XCTAssertNil(appState.editorFindHost.controller.query)
        XCTAssertNil(appState.editorFindHost.controller.session)
    }

    func testHostedSourcePreviewFindBypassesDisabledTypewriterSync() async throws {
        let document = makeLongPreviewDocument()
        let fixture = try makeWorkspaceFixture(files: ["post.md": document.source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourcePreview)
        appState.preferences.setTypewriterSyncEnabled(false)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens in source and preview") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
                && appState.isPreviewVisible
        }
        XCTAssertFalse(appState.preferences.typewriterSyncEnabled)

        let host = makeWorkspaceHost(appState: appState, width: 1280, height: 760)
        registerTeardown(host: host, fixture: fixture)

        let webView = try await waitForView(WKWebView.self, in: host.window)
        try await waitUntil("live preview renders the target source line", timeout: 8) {
            let value = try await webView.evaluateJavaScript(
                "document.querySelector('[data-line=\"\(document.targetLine)\"]') !== null"
            )
            return value as? Bool == true
        }
        let targetStartsOffscreen = try await webView.evaluateJavaScript(
            """
            (() => {
              const target = document.querySelector('[data-line="\(document.targetLine)"]');
              return window.scrollY === 0 && target.getBoundingClientRect().top >= window.innerHeight;
            })()
            """
        ) as? Bool
        XCTAssertEqual(targetStartsOffscreen, true)

        let sourceBefore = appState.currentDocument.text
        openFindBar(appState, query: document.needle)
        let expectedRange = (document.source as NSString).range(of: document.needle)

        try await waitUntil("production editor applies the exact find selection") {
            EditorSelectionProbe.appliedEditorSelection(in: host.window)?.range == expectedRange
        }
        try await waitUntil("editor selection scrolls the live preview to the matching block") {
            // Explicit navigation forwards the selected source line as a forced intent.
            // `scrollRangeToVisible` only promises that the match becomes visible; it does
            // not promise that the match itself is placed near the top of either viewport.
            let value = try await webView.evaluateJavaScript(
                """
                (() => {
                  const target = document.querySelector('[data-line="\(document.targetLine)"]');
                  const rect = target.getBoundingClientRect();
                  return window.scrollY > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
                })()
                """
            )
            return value as? Bool == true
        }

        XCTAssertEqual(appState.currentDocument.text, sourceBefore)
        XCTAssertEqual(appState.currentDocument.text.utf8.elementsEqual(sourceBefore.utf8), true)
        XCTAssertTrue(appState.isPreviewVisible)
    }

    func testHostedSourcePreviewFindBypassesActivePreviewScrollOwner() async throws {
        let document = makeTwoMatchPreviewDocument()
        let fixture = try makeWorkspaceFixture(files: ["post.md": document.source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourcePreview)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens in source and preview") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
                && appState.isPreviewVisible
        }

        let host = makeWorkspaceHost(appState: appState, width: 1280, height: 760)
        registerTeardown(host: host, fixture: fixture)
        let webView = try await waitForView(WKWebView.self, in: host.window)
        try await waitUntil("live preview renders the second match", timeout: 8) {
            let value = try await webView.evaluateJavaScript(
                "document.querySelector('[data-line=\"\(document.secondLine)\"]') !== null"
            )
            return value as? Bool == true
        }

        let sourceBefore = appState.currentDocument.text
        openFindBar(appState, query: document.needle)
        try await waitUntil("first find match is selected") {
            EditorSelectionProbe.appliedEditorSelection(in: host.window)?.range == document.firstRange
                && appState.editorFindHost.controller.session?.currentOrdinal == 1
        }
        let secondStartsOffscreen = try await webView.evaluateJavaScript(
            """
            document.querySelector('[data-line="\(document.secondLine)"]')
              .getBoundingClientRect().top >= window.innerHeight
            """
        ) as? Bool
        XCTAssertEqual(secondStartsOffscreen, true)

        let scrollCoordinator = try XCTUnwrap(EditorPreviewScrollCoordinator.latestDebugInstance)
        try await waitUntil("first match scroll ownership decays") {
            scrollCoordinator.scrollOwner == .none
        }
        // Drive the live callback installed by `WorkspaceWindow`, then navigate before
        // its 100 ms preview-owner token can decay. The forced navigation intent must
        // reach the same live WebView without letting the queued editor echo undo it.
        let previewController = try XCTUnwrap(webView.navigationDelegate as? PreviewController)
        previewController.onPreviewScrolled?(1)
        XCTAssertEqual(scrollCoordinator.scrollOwner, .preview)
        let previousDeliveryID = scrollCoordinator.previewScrollDeliveryReceipt?.requestID ?? 0
        appState.stepEditorFindFromBarControl(.next)

        try await waitUntil("second find match is selected") {
            EditorSelectionProbe.appliedEditorSelection(in: host.window)?.range == document.secondRange
        }
        try await waitUntil("forced preview navigation is delivered") {
            guard let receipt = scrollCoordinator.previewScrollDeliveryReceipt else { return false }
            guard receipt.requestID > previousDeliveryID else { return false }
            guard receipt.ownerAtDispatch == .preview else {
                XCTFail(
                    "Preview request \(receipt.requestID) dispatched under " +
                        "\(receipt.ownerAtDispatch), expected preview ownership"
                )
                return true
            }
            guard receipt.succeeded else {
                XCTFail(
                    "Preview delivery failed for request \(receipt.requestID), line \(receipt.line)"
                )
                return true
            }
            guard receipt.line == document.secondLine else {
                XCTFail(
                    "Preview delivered line \(receipt.line), expected \(document.secondLine) " +
                        "for request \(receipt.requestID)"
                )
                return true
            }
            return true
        }
        try await waitUntil("second match becomes visible after preview-owned handoff") {
            let value = try await webView.evaluateJavaScript(
                """
                (() => {
                  const target = document.querySelector('[data-line="\(document.secondLine)"]');
                  const rect = target.getBoundingClientRect();
                  return window.scrollY > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
                })()
                """
            )
            return value as? Bool == true
        }

        XCTAssertEqual(appState.currentDocument.text, sourceBefore)
        XCTAssertEqual(appState.currentDocument.text.utf8.elementsEqual(sourceBefore.utf8), true)
    }

    func testHostedMarkedTextCommandsStayInFindFieldAndDoNotMutateDocument() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "document source"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }

        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "")
        let field = try await waitForFindQueryField(in: host.window)
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let coordinator = try XCTUnwrap(field.delegate as? EditorFindQueryField.Coordinator)
        let sourceBefore = appState.currentDocument.text

        fieldEditor.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fieldEditor.hasMarkedText())
        XCTAssertFalse(coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertFalse(coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.currentDocument.text, sourceBefore)
        XCTAssertTrue(fieldEditor.hasMarkedText())
        fieldEditor.unmarkText()
    }

    func testHostedFindToWorkspaceSearchHandoffSupersedesOlderFindFocusWhileHostIsIneligible() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }

        // Keep the host non-key so Find's real key-window-only retry remains pending. Search
        // has the existing designated-window test seam, allowing its newer intent to take a
        // real first responder without adding a Find-only production hook.
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "alpha")
        _ = try await waitForFindQueryField(in: host.window)
        let findRequest = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(findRequest, 0)
        XCTAssertNotEqual(appState.editorFindHost.ui.focusAppliedID, findRequest)

        appState.workspaceSearchFocusKeyWindowCheck = { $0 === host.window }
        appState.focusWorkspaceSearch()
        let searchRequest = appState.workspaceSearchUI.focusRequestID

        try await waitUntil("workspace search owns the real hosted field editor") {
            appState.workspaceSearchUI.focusAppliedID == searchRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
        }

        // App-hosted unit tests cannot make their utility window the process key window.
        // This therefore proves token supersession and real Search first-responder ownership
        // while the older Find retry remains ineligible. The eligible-after-handoff race
        // stays open for an out-of-process two-window acceptance gate.
        XCTAssertEqual(appState.editorFindHost.ui.focusSupersededID, findRequest)
        XCTAssertNotEqual(appState.editorFindHost.ui.focusAppliedID, findRequest)
        XCTAssertTrue(WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window))
        XCTAssertNotNil(findQueryField(in: host.window), "Find stays open during the focus handoff")
    }
}
