import AppKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import WebKit
import WorkspaceKit
import XCTest

@MainActor
extension ExportHTMLCommandAppTests {
    func testSnapshotCapturesExactSourceRevisionAssetsThemeAndMonotonicIdentity() throws {
        let fixture = try makeFixture(text: "---\ntitle: 'A/B: C'\n---\n# Snapshot\n")
        fixture.appState.preferences.setPreviewTheme(.dark)
        guard case let .success(snapshot) = fixture.appState.captureExportHTMLSnapshot() else {
            return XCTFail("Expected a snapshot")
        }
        XCTAssertTrue(snapshot.session === fixture.session)
        XCTAssertEqual(snapshot.textChange.text, fixture.session.text)
        XCTAssertEqual(snapshot.textChange.version, fixture.session.version)
        XCTAssertEqual(snapshot.textChange.fileKind, .markdown)
        XCTAssertEqual(snapshot.textChange.fileURL, fixture.session.fileURL)
        XCTAssertEqual(snapshot.workspaceRootURL, fixture.root)
        XCTAssertEqual(snapshot.defaultDirectoryURL, fixture.root)
        XCTAssertEqual(snapshot.defaultFileName, "post.html")
        XCTAssertEqual(snapshot.theme, .dark)
        fixture.session.replaceText("# Changed")
        fixture.appState.preferences.setPreviewTheme(.light)
        guard case let .success(next) = fixture.appState.captureExportHTMLSnapshot() else {
            return XCTFail("Expected another snapshot")
        }
        XCTAssertGreaterThan(next.operationID, snapshot.operationID)
        XCTAssertEqual(snapshot.textChange.text, "---\ntitle: 'A/B: C'\n---\n# Snapshot\n")
        XCTAssertEqual(snapshot.theme, .dark)
    }

    func testDocumentSwitchAndCloseFenceBothPanelAndPreparedArtifact() async throws {
        for atArtifact in [false, true] {
            for close in [false, true] {
                let fixture = try makeFixture()
                let destination = fixture.exportsDirectory.appendingPathComponent("stale.html")
                let change = {
                    fixture.appState.currentDocument = DocumentSession(
                        text: close ? "" : "# Another document", fileKind: .markdown
                    )
                }
                let recorder = fixture.record(returning: [destination], whilePanelIsOpen: {
                    if !atArtifact { change() }
                })
                if atArtifact { fixture.appState.exportHTMLOperations.didPrepareArtifact = { change() } }
                try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
                XCTAssertEqual(recorder.results.map(\.result), [.stopped(.documentChanged)])
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertTrue(recorder.controllers.allSatisfy(\.isInvalidated))
                XCTAssertNil(fixture.appState.exportHTMLOperations.activeTask)
            }
        }
    }

    func testWorkspaceCloseAndEditFenceThePreparedArtifact() async throws {
        for edit in [false, true] {
            let fixture = try makeFixture()
            let destination = fixture.exportsDirectory.appendingPathComponent("stale.html")
            let recorder = fixture.record(returning: [destination])
            fixture.appState.exportHTMLOperations.didPrepareArtifact = {
                if edit { fixture.session.replaceText("# Edited") }
                else { fixture.appState.workspaceRootURL = nil }
            }
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
            XCTAssertEqual(recorder.results.map(\.result), [.stopped(edit ? .documentChanged : .workspaceChanged)])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testPanelCancelAndProgressCancelAreSilentAndReleaseTheController() async throws {
        for cancelProgress in [false, true] {
            let fixture = try makeFixture()
            let destination = fixture.exportsDirectory.appendingPathComponent("cancel.html")
            let recorder = fixture.record(returning: cancelProgress ? [destination] : [])
            if cancelProgress {
                fixture.appState.exportHTMLOperations.didPrepareArtifact = {
                    guard case .exporting = fixture.appState.exportHTMLStatus else {
                        return XCTFail("Expected accessible export progress")
                    }
                    fixture.appState.cancelExportHTML()
                }
            }
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
            XCTAssertEqual(recorder.results.map(\.result), [.stopped(.cancelled)])
            XCTAssertNil(fixture.appState.exportHTMLStatus)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(recorder.controllers.allSatisfy(\.isInvalidated))
            XCTAssertNil(fixture.appState.exportHTMLOperations.offscreenController)
        }
    }

    func testWeakControllerAndWebViewAreReleasedAfterSuccessFailureAndCancel() async throws {
        for outcome in [0, 1, 2] {
            let fixture = try makeFixture()
            weak var controller: PreviewController?
            weak var webView: WKWebView?
            fixture.appState.exportHTMLOperations.destinationChooser = { _ in
                controller = fixture.appState.exportHTMLOperations.offscreenController
                webView = controller?.webView
                return outcome == 2 ? nil : fixture.exportsDirectory.appendingPathComponent("release.html")
            }
            if outcome ==
                1 { fixture.appState.exportHTMLOperations.injectedWriteOutcome = .notCommitted(.ownedDestination) }
            var task = fixture.appState.exportCurrentDocumentAsHTML()
            try await XCTUnwrap(task).value
            task = nil
            await Task.yield()
            XCTAssertNil(controller)
            XCTAssertNil(webView)
            XCTAssertNil(fixture.appState.exportHTMLOperations.activeTask)
        }
    }

    func testDestinationIdentityCapturedAtPanelReturnCannotReplaceARacedLeaf() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("race.html")
        try Data("original".utf8).write(to: destination)
        let recorder = fixture.record(returning: [destination])
        fixture.appState.exportHTMLOperations.didInspectDestination = {
            try? FileManager.default.removeItem(at: destination)
            try? Data("other writer".utf8).write(to: destination)
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertEqual(recorder.results.map(\.result), [.written(.notCommitted(.destinationIdentityChanged))])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "other writer")
    }

    func testEveryInvocationRequiresAFreshPanelResultAndNeverReusesACancelledDestination() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("fresh.html")
        let recorder = fixture.record(returning: [nil, destination])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertNil(fixture.appState.exportHTMLStatus)
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.results.first?.result, .stopped(.cancelled))
        guard case let .exported(commit, _) = recorder.results.last?.result
        else { return XCTFail("Expected fresh export") }
        XCTAssertEqual(commit.selectedURL, destination)
        XCTAssertEqual(recorder.results.map(\.operationID), [1, 2])
    }

    func testClosingTheOriginWindowFencesThePreparedArtifact() async throws {
        let fixture = try makeFixture()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        fixture.appState.exportHTMLOperations.panelWindowProvider = { window }
        let destination = fixture.exportsDirectory.appendingPathComponent("closed.html")
        let recorder = fixture.record(returning: [destination])
        fixture.appState.exportHTMLOperations.didPrepareArtifact = { window.close() }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertEqual(recorder.results.map(\.result), [.stopped(.documentChanged)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(fixture.appState.exportHTMLOperations.windowCloseObserver)
    }

    func testExportPanelFocusChangesDoNotFlushTheDirtySavedBaseline() async throws {
        let fixture = try makeFixture()
        let baseline = fixture.session.text
        fixture.session.replaceText(baseline + "Unsaved addition")
        let before = DocumentState(fixture.session)
        _ = fixture.record(returning: []) {
            XCTAssertNotNil(fixture.appState.exportHTMLOperations.panelOperationID)
            fixture.appState.flushAutosaveAfterWindowResignedKey()
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
        XCTAssertEqual(DocumentState(fixture.session), before)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(fixture.session.fileURL), encoding: .utf8), baseline)
        XCTAssertNil(fixture.appState.exportHTMLOperations.panelOperationID)
        fixture.appState.flushAutosaveAfterWindowResignedKey()
        XCTAssertFalse(fixture.session.isDirty, "Ordinary focus autosave still runs after the panel ends")
    }

    func testUnavailableOwnershipAndRecoveryLoadFailureRefuseBeforeThePanel() throws {
        for recovery in [false, true] {
            let fixture = try makeFixture()
            if recovery { fixture.appState.workspaceMutationTextRecoveryLoadFailed = true }
            else {
                let other = DocumentSession(text: "# Recovered", fileKind: .markdown)
                fixture.appState.sessionCache[fixture.root.appendingPathComponent("other.md")] = other
                fixture.appState
                    .unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(other)] = .unavailable(fileURL: nil)
            }
            var panelCalls = 0
            fixture.appState.exportHTMLOperations.destinationChooser = { _ in panelCalls += 1; return nil }
            XCTAssertNil(fixture.appState.exportCurrentDocumentAsHTML())
            XCTAssertEqual(panelCalls, 0)
            XCTAssertEqual(
                fixture.appState.exportHTMLNotice?.group,
                recovery ? .recoveryUnavailable : .saveDocumentFirst
            )
        }
    }
}
