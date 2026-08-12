import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
final class EditorReplaceBatchSpikeAppTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.isReleasedWhenClosed = false
            window.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    func testMinimalEnclosingRangeUsesTheRealAppSourceContract() throws {
        let source = "one two one"
        let session = DocumentSession(
            text: source,
            url: URL(fileURLWithPath: "/tmp/plainsong-replace-r0-\(UUID().uuidString).md"),
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false
        )
        let hosted = try makeAppBackedFixture(session: session, appState: appState)
        let ranges = TextSearchEngine.matches(
            in: source,
            query: TextSearchQuery(pattern: "one", caseSensitivity: .sensitive),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)

        let result = hosted.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: .minimalEnclosingRange,
            in: hosted.textView
        )

        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.nativeEditCount, 1)
        XCTAssertEqual(session.text, "ONE two ONE")
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(
            MarkdownTextView.textStorage(of: hosted.textView)?.string,
            "ONE two ONE"
        )
    }

    private struct AppFixture {
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func makeAppBackedFixture(
        session: DocumentSession,
        appState: AppState
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
            documentIdentity: EditorDocumentIdentity(rawValue: "replace-r0-app"),
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
}
