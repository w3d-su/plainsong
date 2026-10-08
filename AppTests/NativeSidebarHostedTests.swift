import AppKit
@testable import EditorKit
@testable import Plainsong
import UniformTypeIdentifiers
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesArrowSelectionOpensTwoFilesWithoutRequestingEditorFocus() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "a", "b.md": "b", "c.md": "c"])
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") { state.currentDocument.fileURL?.lastPathComponent == "a.md" }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        var table: NSTableView?
        try await waitUntil("native Files list mounts") {
            table = self.firstDescendant(of: NSTableView.self, in: host.window.contentView)
            return (table?.numberOfRows ?? 0) >= 4
        }
        let list = try XCTUnwrap(table)
        host.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(host.window.makeFirstResponder(list))
        let focusBefore = state.editorFocusRequestID
        for file in ["b.md", "c.md"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: host.window.windowNumber,
                                                       context: nil, characters: "\u{f701}",
                                                       charactersIgnoringModifiers: "\u{f701}",
                                                       isARepeat: false, keyCode: 125))
            host.window.sendEvent(event)
            try await waitUntil("arrow selection opens \(file)") {
                state.currentDocument.fileURL?.lastPathComponent == file
            }
            XCTAssertEqual(state.editorFocusRequestID, focusBefore)
            XCTAssertTrue(host.window.firstResponder === list)
        }
        let firstNode = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" })
        state.selectWorkspaceNode(id: firstNode.id) // Default mouse/menu behavior remains focused.
        XCTAssertNotEqual(state.editorFocusRequestID, focusBefore)
    }

    func testNativeFilesSingleMouseClickStillSelectsDraggableRow() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "a", "b.md": "b"])
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") { state.currentDocument.fileURL?.lastPathComponent == "a.md" }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        var table: NSTableView?
        try await waitUntil("native Files list mounts") {
            table = self.firstDescendant(of: NSTableView.self, in: host.window.contentView)
            return (table?.numberOfRows ?? 0) >= 3
        }
        let list = try XCTUnwrap(table)
        host.window.makeKeyAndOrderFront(nil)
        host.window.makeFirstResponder(list)
        guard host.window.isKeyWindow else {
            throw XCTSkip(
                "Single-click mouse acceptance requires an active key window; verify in the separately signed copy"
            )
        }
        let row = list.rect(ofRow: list.numberOfRows - 1)
        let point = list.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: host.window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: host.window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        // Native drag tracking consumes mouse-up from the application's event queue.
        // Queue it before entering mouseDown, rather than sending it after tracking returns.
        NSApp.postEvent(up, atStart: false)
        list.mouseDown(with: down)
        try await waitUntil("single click opens draggable b.md") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md"
        }
        XCTAssertEqual(state.workspaceTree?.selectedNode?.name, "b.md")
    }
}

@MainActor
final class NativeSidebarDragTests: XCTestCase {
    func testImageDragOffersNodeIDForMovesAndFileURLForEditorDrop() async throws {
        let url = URL(fileURLWithPath: "/private/tmp/sidebar-image.png")
        let provider = WorkspaceSidebarDragProvider.make(nodeID: "images/sidebar-image.png", imageURL: url)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let imageURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = object as? NSURL { continuation.resume(returning: url as URL) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([imageURL as NSURL])
        XCTAssertEqual(MarkdownSTTextView.imageFileURLs(from: pasteboard), [url])
        let textProvider = WorkspaceSidebarDragProvider.make(nodeID: "a.md", imageURL: nil)
        XCTAssertTrue(textProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertFalse(textProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    }
}
