import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
@testable import WorkspaceKit
import XCTest

@MainActor
extension ExportHTMLCommandAppTests {
    func testSuccessCancelFailureAndIndeterminateLeaveEditorPreviewAndDocumentStateUnchanged() async throws {
        for terminal in ["success", "cancel", "failure", "indeterminate"] {
            let source = (0 ..< 80).map { "## Visible block \($0)\n\nParagraph \($0)." }.joined(separator: "\n\n")
            let fixture = try makeFixture(text: source)
            fixture.session.replaceText(source + "\nUnsaved tail")
            fixture.appState.cancelAutosave(for: fixture.session)
            let mounted = try mountExportTestEditor(fixture)
            defer { mounted.window.contentView = nil; mounted.window.orderOut(nil) }
            mounted.textView.textSelection = NSRange(location: 3, length: 7)
            mounted.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 80))
            mounted.scrollView.reflectScrolledClipView(mounted.scrollView.contentView)
            let visible = PreviewController()
            defer { visible.invalidate() }
            visible.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 300)
            visible.setTheme("dark")
            guard case let .completed(renderID) = await visible.renderForExport(fixture.session.currentTextChange)
            else {
                return XCTFail("Visible preview must render before isolation is tested")
            }
            _ = try await visible.webView.evaluateJavaScript("window.scrollTo(0, 200); true")
            let previewBefore = try await visible.webView.evaluateJavaScript(
                "JSON.stringify([window.scrollX, window.scrollY, document.documentElement.dataset.theme, document.body.innerHTML])"
            ) as? String
            let documentBefore = DocumentState(fixture.session)
            let selectionBefore = mounted.textView.textSelection
            let scrollBefore = mounted.scrollView.contentView.bounds.origin
            let recents = fixture.appState.recentItemURLs
            let tree = fixture.appState.workspaceTree
            let recoveryIDs = Set(fixture.appState.workspaceMutationRecoveries.keys)
            let recoveryRecords = Set(fixture.appState.workspaceMutationOperationRecoveryRecords.keys)
            let quarantine = fixture.appState.detachedSessionURLs
            let ownership = fixture.appState.unanchoredManagedSessionOwnershipProofs
            let binding = fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.session)]
            let destination = fixture.exportsDirectory.appendingPathComponent("isolation.html")
            let recorder = fixture.record(returning: terminal == "cancel" ? [] : [destination])
            if terminal ==
                "failure"
            {
                fixture.appState.exportHTMLOperations.injectedWriteOutcome = .notCommitted(.ownedDestination)
            }
            if terminal == "indeterminate" {
                fixture.appState.exportHTMLOperations.injectedWriteOutcome = .indeterminate(
                    ExportArtifactIndeterminateWrite(
                        reason: .cleanupFailed, selectedURL: destination, destinationState: .unknown,
                        residue: .retained(fixture.root.appendingPathComponent("unknown"), holding: .unknown),
                        stagingURL: nil, itemReplacementDirectoryURL: nil, unprovenDirectoryURLs: [],
                        residueIsInPurgeableTemporaryFolder: false
                    )
                )
            }
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value
            XCTAssertEqual(recorder.results.count, 1)
            XCTAssertEqual(DocumentState(fixture.session), documentBefore)
            XCTAssertTrue(fixture.appState.currentDocument === fixture.session)
            XCTAssertEqual(mounted.textView.textSelection, selectionBefore)
            XCTAssertEqual(mounted.scrollView.contentView.bounds.origin, scrollBefore)
            XCTAssertEqual(mounted.textView.text, documentBefore.text)
            XCTAssertEqual(fixture.appState.recentItemURLs, recents)
            XCTAssertEqual(fixture.appState.workspaceTree, tree)
            XCTAssertEqual(Set(fixture.appState.workspaceMutationRecoveries.keys), recoveryIDs)
            XCTAssertEqual(Set(fixture.appState.workspaceMutationOperationRecoveryRecords.keys), recoveryRecords)
            XCTAssertEqual(fixture.appState.detachedSessionURLs, quarantine)
            XCTAssertEqual(fixture.appState.unanchoredManagedSessionOwnershipProofs, ownership)
            XCTAssertEqual(
                fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.session)]?.sha256Digest,
                binding?.sha256Digest
            )
            XCTAssertEqual(visible.scrollDeliveryState.completedRenderID, renderID)
            let previewAfter = try await visible.webView.evaluateJavaScript(
                "JSON.stringify([window.scrollX, window.scrollY, document.documentElement.dataset.theme, document.body.innerHTML])"
            ) as? String
            XCTAssertEqual(previewAfter, previewBefore)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(fixture.session.fileURL), encoding: .utf8), source)
            // The original persisted baseline is still authoritative after every result.
            fixture.session.replaceText(source)
            XCTAssertFalse(fixture.session.isDirty)
        }
    }

    func testPDFAndPrintLeaveEditorPreviewAndDocumentStateUnchanged() async throws {
        for product in ["pdf", "print"] {
            let source = (0 ..< 40).map { "## Visible block \($0)\n\nParagraph \($0)." }.joined(separator: "\n\n")
            let fixture = try makeFixture(text: source)
            fixture.session.replaceText(source + "\nUnsaved tail")
            fixture.appState.cancelAutosave(for: fixture.session)
            let mounted = try mountExportTestEditor(fixture)
            defer { mounted.window.contentView = nil; mounted.window.orderOut(nil) }
            mounted.textView.textSelection = NSRange(location: 3, length: 7)
            mounted.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
            mounted.scrollView.reflectScrolledClipView(mounted.scrollView.contentView)
            let visible = PreviewController()
            defer { visible.invalidate() }
            visible.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 300)
            visible.setTheme("dark")
            guard case let .completed(renderID) = await visible.renderForExport(fixture.session.currentTextChange)
            else { return XCTFail("Visible preview must render") }
            let previewBefore = try await visible.webView.evaluateJavaScript(
                "JSON.stringify([window.scrollY, document.documentElement.dataset.theme, document.body.innerHTML])"
            ) as? String
            let documentBefore = DocumentState(fixture.session)
            let selectionBefore = mounted.textView.textSelection
            let scrollBefore = mounted.scrollView.contentView.bounds.origin
            let recents = fixture.appState.recentItemURLs
            let destination = fixture.exportsDirectory.appendingPathComponent("isolation.pdf")
            if product == "pdf" {
                _ = fixture.record(returning: [destination])
                try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            } else {
                fixture.appState.exportHTMLOperations.destinationChooser = { _ in
                    XCTFail("Print must not choose a file")
                    return destination
                }
                fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
                try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
            XCTAssertEqual(DocumentState(fixture.session), documentBefore)
            XCTAssertTrue(fixture.appState.currentDocument === fixture.session)
            XCTAssertEqual(mounted.textView.textSelection, selectionBefore)
            XCTAssertEqual(mounted.scrollView.contentView.bounds.origin, scrollBefore)
            XCTAssertEqual(fixture.appState.recentItemURLs, recents)
            XCTAssertEqual(visible.scrollDeliveryState.completedRenderID, renderID)
            let previewAfter = try await visible.webView.evaluateJavaScript(
                "JSON.stringify([window.scrollY, document.documentElement.dataset.theme, document.body.innerHTML])"
            ) as? String
            XCTAssertEqual(previewAfter, previewBefore)
        }
    }

    private func mountExportTestEditor(_ fixture: Fixture) throws -> MountedExportEditor {
        let binding = fixture.appState.editorDocumentBinding(for: fixture.session)
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = fixture.session.text
        let representable = MarkdownTextView(
            text: binding.text, styledText: nil, selection: .constant(.init(location: 0, length: 0)),
            showsLineNumbers: false, documentIdentity: nil, documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle, documentSourceContract: binding.sourceContract
        )
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        textView.layoutSubtreeIfNeeded()
        return MountedExportEditor(window: window, scrollView: scrollView, textView: textView, coordinator: coordinator)
    }

    private struct MountedExportEditor {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }
}
