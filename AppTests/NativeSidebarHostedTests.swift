import AppKit
@testable import EditorKit
@testable import Plainsong
import UniformTypeIdentifiers
import WorkspaceKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesArrowSelectionOpensTwoFilesWithoutRequestingEditorFocus() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "a", "b.md": "b", "c.md": "c"])
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") { state.currentDocument.fileURL?.lastPathComponent == "a.md" }
        // A deferred pick is refused while the open reload's capture still lags; wait
        // for it to install so the first arrow cannot hit that window (29c).
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
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
            try sendFilesArrowDown(to: host.window)
            try await waitUntil("arrow selection opens \(file)") {
                state.currentDocument.fileURL?.lastPathComponent == file
            }
            XCTAssertEqual(state.editorFocusRequestID, focusBefore)
            XCTAssertTrue(host.window.firstResponder === list)
        }
        let firstNode = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" })
        // A watcher reload for the fixture's own writes can still be in flight here, and a pick
        // is refused while its capture lags (CI run 39813122776); wait for it to install.
        try await waitUntil("any watcher reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        // Default mouse/menu behavior remains focused.
        XCTAssertTrue(state.selectWorkspaceNode(id: firstNode.id), "the pick was refused")
        XCTAssertNotEqual(state.editorFocusRequestID, focusBefore)
    }

    func testNativeFilesDroppedPickRevertsHighlightBeforeHeldReloadInstalls() async throws {
        let scanner = HeldWorkspaceDirectoryScanner()
        let fixture = try makeWorkspaceFixture(
            files: ["a.md": "a", "b.md": "b", "c.md": "c"],
            directoryScanner: scanner
        )
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
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
        let aRow = list.selectedRow
        XCTAssertGreaterThanOrEqual(aRow, 0)
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        FilesSelectionDeferral.debugRetryAttemptLimit = 4
        addTeardownBlock { @MainActor in
            FilesSelectionDeferral.debugRetryAttemptLimit = nil
            await scanner.release()
        }

        await scanner.hold()
        state.scheduleWorkspaceReload(
            root: fixture.root, selectFirstIfNeeded: false, errorTitle: "Reload"
        )
        try await waitUntil("the reload is parked in the scanner") { await scanner.isHeld }

        try sendFilesArrowDown(to: host.window)
        try await waitUntil("the dropped pick exhausted its retry budget") {
            guard let deferral = FilesSelectionDeferral.latestDebugInstance else { return false }
            let refusedPicks = deferral.openAttempts.filter { $0.id == bID && !$0.landed }
            return refusedPicks.count == 4 && deferral.pendingID == nil
        }
        try await waitUntil("the List highlight returns to a.md") {
            list.selectedRow == aRow
        }
        let deferral = try XCTUnwrap(FilesSelectionDeferral.latestDebugInstance)
        XCTAssertEqual(deferral.openAttempts.filter { $0.id == bID && !$0.landed }.count, 4)
        XCTAssertNil(deferral.pendingID)
        let scannerIsHeld = await scanner.isHeld
        XCTAssertTrue(scannerIsHeld)
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "a.md")
        XCTAssertEqual(list.selectedRow, aRow)

        await scanner.release()
        try await waitUntil("the held reload installs") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "a.md")
    }

    /// A burst of arrows lands on the last file without reverting, and keeps focus in the
    /// navigator. Ordering is covered by the held-reload test's attempt-index assertion.
    func testNativeFilesRapidArrowSelectionLandsOnLastFileWithoutReverting() async throws {
        let fixture = try makeWorkspaceFixture(
            files: ["a.md": "a", "b.md": "b", "c.md": "c", "d.md": "d"]
        )
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        // Same as the two-file test: settle the open reload before the arrows so no
        // deferred pick is refused by a lagging capture it was not meant to meet (29c).
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        var table: NSTableView?
        try await waitUntil("native Files list mounts") {
            table = self.firstDescendant(of: NSTableView.self, in: host.window.contentView)
            return (table?.numberOfRows ?? 0) >= 5
        }
        let list = try XCTUnwrap(table)
        host.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(host.window.makeFirstResponder(list))
        let focusBefore = state.editorFocusRequestID
        let dRow = list.numberOfRows - 1
        for _ in 0 ..< 3 {
            try sendFilesArrowDown(to: host.window)
        }
        try await waitUntil("the last arrow's file is open") {
            state.currentDocument.fileURL?.lastPathComponent == "d.md"
        }
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "d.md")
        XCTAssertEqual(list.selectedRow, dRow)
        XCTAssertEqual(state.editorFocusRequestID, focusBefore)
        XCTAssertTrue(host.window.firstResponder === list)
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

    /// Handoff 29c MEDIUM: a pick refused while a reload's installed capture lags the
    /// workspace generation must retry until it installs, and a newer pick supersedes
    /// an older pick's retry without the older one ever landing. The scanner parks every
    /// capture while held so the lag is deterministic instead of a race the 25 ms poll
    /// happens to meet; the deferral's attempt log proves each pick's outcome.
    func testNativeFilesDeferredOpenRetriesHeldReloadAndNewestPickWins() async throws {
        let scanner = HeldWorkspaceDirectoryScanner()
        let fixture = try makeWorkspaceFixture(
            files: ["a.md": "a", "b.md": "b", "c.md": "c"],
            directoryScanner: scanner
        )
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
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
        let nodes = try XCTUnwrap(state.workspaceTree?.root.children)
        let bID = try XCTUnwrap(nodes.first { $0.name == "b.md" }?.id)
        let cID = try XCTUnwrap(nodes.first { $0.name == "c.md" }?.id)

        // Hold a reload in flight: the generation advances now but no capture can
        // install until released, so every deferred pick is refused deterministically.
        await scanner.hold()
        state.scheduleWorkspaceReload(
            root: fixture.root, selectFirstIfNeeded: false, errorTitle: "Reload"
        )
        try await waitUntil("the reload is parked in the scanner") { await scanner.isHeld }
        XCTAssertNotEqual(
            state.workspaceInstalledCaptureGeneration, state.workspaceGeneration,
            "the held reload must leave the installed capture lagging"
        )

        try sendFilesArrowDown(to: host.window) // picks b.md
        var observedDeferral: FilesSelectionDeferral?
        try await waitUntil("the first pick was refused under the lag") {
            guard let deferral = FilesSelectionDeferral.latestDebugInstance else { return false }
            observedDeferral = deferral
            return deferral.openAttempts.contains { $0.id == bID && !$0.landed }
        }
        let deferral = try XCTUnwrap(observedDeferral)
        try sendFilesArrowDown(to: host.window) // picks c.md while b.md's retry sleeps
        try await waitUntil("the newest pick was refused three times under the lag") {
            deferral.openAttempts.filter { $0.id == cID && !$0.landed }.count >= 3
        }
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "a.md",
                       "a held reload must keep both picks refused")

        await scanner.release()
        try await waitUntil("the newest pick opens after the capture installs") {
            state.currentDocument.fileURL?.lastPathComponent == "c.md"
        }
        // Give the superseded retry its next turn: it must have exited instead of landing.
        try await Task.sleep(nanoseconds: 50_000_000)
        await Task.yield()
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "c.md")

        let attempts = deferral.openAttempts
        let firstC = try XCTUnwrap(attempts.firstIndex { $0.id == cID })
        XCTAssertFalse(
            attempts[firstC...].contains { $0.id == bID },
            "the older pick must stop retrying after the newest pick starts: \(attempts)"
        )
        XCTAssertFalse(
            attempts.contains { $0.id == bID && $0.landed },
            "the older pick must never land after the newer one: \(attempts)"
        )
        XCTAssertEqual(
            attempts.filter { $0.id == cID && $0.landed }.count, 1,
            "the newest pick must land exactly once: \(attempts)"
        )
        XCTAssertEqual(state.editorFocusRequestID, focusBefore,
                       "arrow selection must not request editor focus")
        XCTAssertTrue(host.window.firstResponder === list)
    }

    /// A mouse pick retries for up to ~5 s while a reload's capture lags. If the user
    /// moved first responder elsewhere (here, the find field) before the pick lands,
    /// the landing must not yank focus back into the editor.
    func testNativeFilesDelayedMousePickKeepsFocusTheUserMovedElsewhere() async throws {
        let scanner = HeldWorkspaceDirectoryScanner()
        let fixture = try makeWorkspaceFixture(
            files: ["a.md": "alpha", "b.md": "beta"],
            directoryScanner: scanner
        )
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        var table: NSTableView?
        try await waitUntil("native Files list mounts") {
            table = self.firstDescendant(of: NSTableView.self, in: host.window.contentView)
            return (table?.numberOfRows ?? 0) >= 3
        }
        let list = try XCTUnwrap(table)
        host.window.makeKeyAndOrderFront(nil)

        openFindBar(state, query: "zz")
        let field = try await waitForFindQueryField(in: host.window)
        // The hosted window never becomes key, so the find request can never apply;
        // supersede it so its retry loop cannot re-arm and re-steal focus later.
        var findUI = state.editorFindHost.ui
        findUI.supersedePendingFocus()
        state.setEditorFindUI(findUI)
        XCTAssertTrue(host.window.makeFirstResponder(list))

        let bID = try XCTUnwrap(
            state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id
        )
        addTeardownBlock { @MainActor in
            await scanner.release()
        }

        await scanner.hold()
        state.scheduleWorkspaceReload(
            root: fixture.root, selectFirstIfNeeded: false, errorTitle: "Reload"
        )
        try await waitUntil("the reload is parked in the scanner") { await scanner.isHeld }
        XCTAssertNotEqual(
            state.workspaceInstalledCaptureGeneration, state.workspaceGeneration,
            "the held reload must leave the installed capture lagging"
        )

        let deferral = FilesSelectionDeferral()
        deferral.open(
            id: bID, requestingEditorFocus: true, pickWindow: host.window, appState: state
        ) {}
        try await waitUntil("the pick was refused under the lag") {
            deferral.openAttempts.contains { $0.id == bID && !$0.landed }
        }

        // The user moves on to the find field while the pick is still retrying.
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(host.window.firstResponder === fieldEditor)
        let focusBefore = state.editorFocusRequestID

        await scanner.release()
        try await waitUntil("b.md opens after the capture installs") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md"
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await Task.yield()

        XCTAssertEqual(
            deferral.openAttempts.filter { $0.id == bID && $0.landed }.count, 1,
            "the pick must land exactly once: \(deferral.openAttempts)"
        )
        XCTAssertEqual(
            state.editorFocusRequestID, focusBefore,
            "a delayed pick must not steal focus the user already moved elsewhere"
        )
        XCTAssertTrue(
            host.window.firstResponder === fieldEditor,
            "first responder must stay on the find field, got \(String(describing: host.window.firstResponder))"
        )
    }

    /// Positive control: the same delayed pick still focuses the editor when first
    /// responder is unchanged since the pick — the user's focus never moved.
    func testNativeFilesDelayedMousePickFocusesEditorWhenFocusStayed() async throws {
        let scanner = HeldWorkspaceDirectoryScanner()
        let fixture = try makeWorkspaceFixture(
            files: ["a.md": "alpha", "b.md": "beta"],
            directoryScanner: scanner
        )
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("sidebar fixture opens") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        var table: NSTableView?
        try await waitUntil("native Files list mounts") {
            table = self.firstDescendant(of: NSTableView.self, in: host.window.contentView)
            return (table?.numberOfRows ?? 0) >= 3
        }
        let list = try XCTUnwrap(table)
        host.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(host.window.makeFirstResponder(list))

        let bID = try XCTUnwrap(
            state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id
        )
        addTeardownBlock { @MainActor in
            await scanner.release()
        }

        await scanner.hold()
        state.scheduleWorkspaceReload(
            root: fixture.root, selectFirstIfNeeded: false, errorTitle: "Reload"
        )
        try await waitUntil("the reload is parked in the scanner") { await scanner.isHeld }
        XCTAssertNotEqual(
            state.workspaceInstalledCaptureGeneration, state.workspaceGeneration,
            "the held reload must leave the installed capture lagging"
        )

        let focusBefore = state.editorFocusRequestID
        let deferral = FilesSelectionDeferral()
        deferral.open(
            id: bID, requestingEditorFocus: true, pickWindow: host.window, appState: state
        ) {}
        try await waitUntil("the pick was refused under the lag") {
            deferral.openAttempts.contains { $0.id == bID && !$0.landed }
        }

        await scanner.release()
        try await waitUntil("b.md opens after the capture installs") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md"
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await Task.yield()

        XCTAssertEqual(
            deferral.openAttempts.filter { $0.id == bID && $0.landed }.count, 1,
            "the pick must land exactly once: \(deferral.openAttempts)"
        )
        XCTAssertGreaterThan(
            state.editorFocusRequestID, focusBefore,
            "a mouse pick whose responder never moved still requests editor focus"
        )
    }
}

/// Sends one real down-arrow key event to `window`, the same path the arrow tests use.
@MainActor
private func sendFilesArrowDown(to window: NSWindow) throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}",
        isARepeat: false, keyCode: 125
    ))
    window.sendEvent(event)
}

/// Parks every snapshot capture completed during `hold()` until `release()` resumes them.
private actor HeldWorkspaceDirectoryScanner: WorkspaceDirectoryScanning {
    private let backing = WorkspaceDirectoryScanner()
    private var holding = false
    private var parkedCaptures: [CheckedContinuation<Void, Never>] = []

    var isHeld: Bool {
        !parkedCaptures.isEmpty
    }

    func hold() {
        holding = true
    }

    func release() {
        holding = false
        let captures = parkedCaptures
        parkedCaptures.removeAll()
        captures.forEach { $0.resume() }
    }

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        let capture = try await backing.snapshotCapture(root: root)
        if holding {
            await withCheckedContinuation { parkedCaptures.append($0) }
        }
        return capture
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
