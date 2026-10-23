import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKit
import UIKit
@preconcurrency import WebKit
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

/// App-hosted tests use the actual production factory, UIDocument, native
/// editor, Files access provider and packaged preview. No successful fake I/O.
@MainActor
final class IOSProductionDocumentWorkflowTests: XCTestCase {
    func testFilesOpenNativeEditPreviewSaveAndReopen() async throws {
        let (fixture, runtime, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.first, scope: .singleFile)
        let handle = try XCTUnwrap(controller.handle)
        XCTAssertEqual(handle.session.text, "# Original\n")
        XCTAssertEqual(runtime.editor.captureSnapshot()?.revision.documentID, handle.identity)
        XCTAssertTrue(try controller.setCommandFocus(
            true,
            expected: handle.identity,
            bindingID: XCTUnwrap(controller.bindingID)
        ))
        let snapshot = try XCTUnwrap(runtime.editor.captureSnapshot())
        let result = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: snapshot.document.text.utf16.count),
            replacementString: "# 已修改\n繁中 👩🏽‍💻\n", newSelection: NSRange(location: 6, length: 0)
        )
        XCTAssertEqual(runtime.editor.apply(IOSAuthorizedEdit(
            bindingID: snapshot.bindingID, baseRevision: snapshot.revision,
            selectionGeneration: snapshot.selectionGeneration, accessGeneration: snapshot.accessGeneration,
            result: result, undoActionName: "Workflow Edit"
        )), .applied(IOSDocumentRevision(documentID: handle.identity, version: snapshot.revision.version + 1)))
        XCTAssertEqual(handle.session.text, runtime.editor.textView.text)
        XCTAssertTrue(handle.session.isDirty)
        try await waitUntil("real packaged preview ready") { runtime.preview.isReady }
        try await waitUntil("native source rendered") {
            try await self.bodyText(runtime.preview).contains("已修改")
        }
        let acknowledgement = try await controller.saveCurrentDocument()
        XCTAssertEqual(acknowledgement.savedText, handle.session.text)
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(try String(contentsOf: fixture.first, encoding: .utf8), acknowledgement.savedText)
        // Re-picking the resource drains/closes its old writer before new grant.
        try await controller.openPickedURL(fixture.first, scope: .singleFile)
        XCTAssertNotEqual(controller.handle?.identity, handle.identity)
        XCTAssertEqual(controller.handle?.session.text, acknowledgement.savedText)
        XCTAssertEqual(runtime.editor.textView.text, acknowledgement.savedText)
    }

    func testFolderRowsReuseTheGrantAndReopenTheDocument() async throws {
        let (fixture, _, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.root, scope: .directory)
        let grant = try XCTUnwrap(controller.currentGrant)
        XCTAssertNil(controller.handle)
        try await controller.openSelectedURL(fixture.first, scope: .singleFile)
        let first = try XCTUnwrap(controller.handle)
        try await controller.openSelectedURL(fixture.second, scope: .singleFile)
        XCTAssertNotEqual(controller.handle?.identity, first.identity)
        XCTAssertEqual(controller.currentGrant?.workspaceID, grant.workspaceID)
        try await controller.openSelectedURL(fixture.first, scope: .singleFile)
        XCTAssertEqual(controller.handle?.session.text, "# Original\n")
        XCTAssertEqual(controller.currentGrant?.workspaceID, grant.workspaceID)
    }

    func testSingleFileSelectionDoesNotAuthorizeItsSibling() async throws {
        let (fixture, _, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.first, scope: .singleFile)
        let handle = try XCTUnwrap(controller.handle)
        do {
            try await controller.openSelectedURL(fixture.second, scope: .singleFile)
            XCTFail("A browser/relative URL must not mint a sibling grant")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.outsideGrant))
        }
        XCTAssertTrue(controller.handle?.session === handle.session)
        XCTAssertEqual(controller.admission.active?.documentID, handle.identity)
    }

    func testNewFileUsesTheGrantedParentAndDoesNotReplaceAnExistingFile() async throws {
        let (fixture, _, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.root, scope: .directory)
        let grant = try XCTUnwrap(controller.currentGrant)
        let parent = IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
            relativePath: "", fileURL: grant.rootURL, resourceID: nil
        )
        try await controller.createDocument(at: parent)
        XCTAssertEqual(controller.handle?.location.relativePath, "Untitled.md")
        try await controller.createDocument(at: parent)
        XCTAssertEqual(controller.handle?.location.relativePath, "Untitled 2.md")
        XCTAssertEqual(try String(contentsOf: fixture.first, encoding: .utf8), "# Original\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Untitled.md").path))
    }

    func testObservationAfterOpeningImmediatelyReceivesTheCurrentDocument() async throws {
        let (fixture, runtime, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.first, scope: .singleFile)
        runtime.scene.startObserving()
        XCTAssertTrue(runtime.scene.chrome.hasDocument)
        XCTAssertEqual(runtime.scene.chrome.documentIdentity, controller.handle?.identity)
        runtime.scene.stopObserving()
    }

    func testMissingPreviewLinkPresentsAnAlertAndKeepsTheProductionDocumentWritable() async throws {
        let (fixture, runtime, controller) = try fixtureRuntime()
        try await controller.openPickedURL(fixture.root, scope: .directory)
        try await controller.openSelectedURL(fixture.first, scope: .singleFile)
        let handle = try XCTUnwrap(controller.handle)
        let binding = controller.bindingID
        controller.previewEvent(.relativeLinkRequested(documentID: handle.identity, href: "missing.md"))
        try await waitUntil("production navigation alert") { runtime.scene.presentedError != nil }

        XCTAssertEqual(runtime.scene.presentedError?.title, "Link Could Not Be Opened")
        XCTAssertEqual(runtime.scene.presentedError?.message, "The linked document could not be opened.")
        XCTAssertNil(controller.snapshot.unavailableReason)
        XCTAssertTrue(controller.handle?.session === handle.session)
        XCTAssertEqual(controller.bindingID, binding)
        XCTAssertTrue(controller.snapshot.documentState?.canWrite == true)
        XCTAssertTrue(runtime.editor.captureSnapshot()?.canWrite == true)
        XCTAssertEqual(runtime.editor.textView.text, "# Original\n")
    }

    private func fixtureRuntime() throws -> (Fixture, IOSProductionRuntime, IOSDocumentSceneController) {
        let fixture = try Fixture()
        do {
            let runtime = try IOSProductionComposition.makeProduction()
            let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
            // Register before any await so an assertion/timeout cannot leak a
            // UIDocument, presenter, scope or WKWebView into the next case.
            addTeardownBlock { @MainActor in
                runtime.stopObserving()
                runtime.scene.stopObserving()
                let closed = await controller.shutdown()
                XCTAssertTrue(closed, "Retained writer must be resolved before releasing test resources")
                if closed {
                    try fixture.remove()
                }
            }
            return (fixture, runtime, controller)
        } catch {
            try? fixture.remove()
            throw error
        }
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out: \(description)")
        throw IOSDocumentFailure.unavailable
    }

    private func bodyText(_ preview: PreviewController) async throws -> String {
        let reply = JavaScriptReply()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reply.finish(.failure(IOSDocumentFailure.unavailable))
            }
            reply.timeout = timeout
            preview.webView.evaluateJavaScript("document.body.innerText") { result, error in
                if let error {
                    reply.finish(.failure(error))
                } else {
                    reply.finish(.success(result as? String ?? ""))
                }
            }
        }
    }
}

@MainActor
private final class JavaScriptReply {
    var continuation: CheckedContinuation<String, Error>?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
}

private struct Fixture {
    let root: URL
    let first: URL
    let second: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        first = root.appendingPathComponent("first.md")
        second = root.appendingPathComponent("second.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Original\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }
}
