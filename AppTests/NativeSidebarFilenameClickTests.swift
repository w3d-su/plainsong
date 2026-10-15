import AppKit
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesSingleClickOnDraggableFilenameOpensEveryPick() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "alpha", "b.md": "beta"])
        let state = fixture.appState
        state.setLayoutMode(.sourceOnly)
        state.openExternalFile(fixture.root)
        try await waitUntil("workspace capture installs") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
                && state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        let host = makeWorkspaceHost(appState: state)
        registerTeardown(host: host, fixture: fixture)
        let list = try await waitForView(NSTableView.self, in: host.window)
        try await waitUntil("both file rows mount") { list.numberOfRows >= 3 }
        host.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(host.window.makeFirstResponder(list))
        for (file, index) in [("b.md", 2), ("a.md", 1), ("b.md", 2)] {
            let row = list.rect(ofRow: index)
            // Hit the draggable icon/name, not empty space at the row's midpoint.
            let point = list.convert(NSPoint(x: row.minX + 72, y: row.midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0
            ))
            NSApp.postEvent(up, atStart: false)
            // Route through the real window so its hit view and drag recognizer participate.
            host.window.sendEvent(down)
            try await waitUntil("filename click opens \(file)") {
                state.currentDocument.fileURL?.lastPathComponent == file
            }
            XCTAssertEqual(state.workspaceTree?.selectedNode?.name, file)
        }
    }
}

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesFailedReadKeepsPreviousSelectionAndAllowsRetry() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "alpha", "b.md": "beta"])
        let state = fixture.appState
        addTeardownBlock { @MainActor in
            let tasks = self.activeTasks(in: state)
            tasks.forEach { $0.cancel() }
            state.closeWorkspace()
            for task in tasks {
                await task.value
            }
            fixture.cleanUp()
        }
        state.openExternalFile(fixture.root)
        try await waitUntil("workspace capture installs") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
                && state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        state.workspaceWatcher?.stop()
        let previousDocument = state.currentDocument
        let previousSelection = state.workspaceTree?.selectedNodeID
        let nodeID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let destination = fixture.root.appendingPathComponent("b.md")
        try Data([0xFF]).write(to: destination)
        state.selectWorkspaceNode(id: nodeID, requestingEditorFocus: false)
        XCTAssertTrue(state.currentDocument === previousDocument)
        XCTAssertEqual(state.currentDocument.text, "alpha")
        XCTAssertNotNil(state.presentedError)
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, previousSelection,
                       "A failed open must not highlight the unopened file or suppress a retry")
        state.presentedError = nil
        try "recovered beta".write(to: destination, atomically: false, encoding: .utf8)
        state.selectWorkspaceNode(id: nodeID, requestingEditorFocus: false)
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, nodeID)
        XCTAssertEqual(state.currentDocument.text, "recovered beta")
        XCTAssertNil(state.presentedError)
    }
}

@MainActor
extension EditorFindHostedGateTests {
    func testNativeFilesSlowReadKeepsMainActorResponsiveAndNewestPickWins() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let original = state.currentDocument
        original.replaceText("alpha unsaved", refreshStatistics: false)
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let cID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "c.md" }?.id)
        let read = HeldFilesSelectionRead()
        defer { read.release() }
        let deferral = FilesSelectionDeferral()
        deferral.beforeFileRead = { read.holdFirstRead() }
        deferral.open(id: bID, requestingEditorFocus: false, pickWindow: nil, appState: state) {}
        try await waitUntil("first file read is held off the main thread") { read.isHeld }
        XCTAssertFalse(read.ranOnMainThread)
        XCTAssertTrue(state.currentDocument === original)
        deferral.open(id: cID, requestingEditorFocus: false, pickWindow: nil, appState: state) {}
        try await waitUntil("newest pick opens while the previous read is still held") {
            state.currentDocument.fileURL?.lastPathComponent == "c.md" && deferral.pendingID == nil
        }
        XCTAssertTrue(read.isHeld)
        XCTAssertEqual(state.currentDocument.text, "gamma")
        read.release()
        try await waitUntil("cancelled older read exits") { read.didExit }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(state.currentDocument.fileURL?.lastPathComponent, "c.md")
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, cID)
        XCTAssertEqual(original.text, "alpha unsaved")
        XCTAssertTrue(original.isDirty)
        let aID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" }?.id)
        XCTAssertTrue(state.selectWorkspaceNode(id: aID, requestingEditorFocus: false))
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(state.currentDocument.text, "alpha unsaved")
        XCTAssertTrue(state.currentDocument.isDirty)
        XCTAssertFalse(deferral.openAttempts.contains { $0.id == bID && $0.landed })
        XCTAssertNil(state.presentedError)
    }

    func testNativeFilesCancelledPickNeverStartsAnOpen() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let original = state.currentDocument
        let previousSelection = state.workspaceTree?.selectedNodeID
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let deferral = FilesSelectionDeferral()
        deferral.open(id: bID, requestingEditorFocus: true, pickWindow: nil, appState: state) {}
        deferral.cancelPendingOpen()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, previousSelection)
        XCTAssertTrue(deferral.openAttempts.isEmpty)
        XCTAssertNil(deferral.pendingID)
    }

    func testNativeFilesCancellingAnInFlightReadKeepsTheCurrentDocument() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let original = state.currentDocument
        let previousSelection = state.workspaceTree?.selectedNodeID
        let focusBefore = state.editorFocusRequestID
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let read = HeldFilesSelectionRead()
        defer { read.release() }
        let deferral = FilesSelectionDeferral()
        deferral.beforeFileRead = { read.holdFirstRead() }
        deferral.open(id: bID, requestingEditorFocus: true, pickWindow: nil, appState: state) {}
        try await waitUntil("file read is held before the navigator unmounts") { read.isHeld }
        deferral.cancelPendingOpen()
        read.release()
        try await waitUntil("cancelled file read exits") { read.didExit }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, previousSelection)
        XCTAssertEqual(state.editorFocusRequestID, focusBefore)
        XCTAssertNil(deferral.pendingID)
        XCTAssertNil(state.presentedError)
    }

    func testNativeFilesFailedDeferredReadDropsHighlightAndCanBeRetried() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let original = state.currentDocument
        let previousSelection = state.workspaceTree?.selectedNodeID
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let destination = fixture.root.appendingPathComponent("b.md")
        try Data([0xFF]).write(to: destination)
        let deferral = FilesSelectionDeferral()
        var dropped = false
        deferral.open(id: bID, requestingEditorFocus: false, pickWindow: nil, appState: state) {
            dropped = true
        }
        try await waitUntil("failed read requests highlight restoration") { dropped }
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, previousSelection)
        XCTAssertNil(deferral.pendingID)
        XCTAssertNotNil(state.presentedError)
        state.presentedError = nil
        try "recovered beta".write(to: destination, atomically: false, encoding: .utf8)
        deferral.open(id: bID, requestingEditorFocus: false, pickWindow: nil, appState: state) {}
        try await waitUntil("the same row can be retried after a failed read") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md" && deferral.pendingID == nil
        }
        XCTAssertEqual(state.currentDocument.text, "recovered beta")
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, bID)
        XCTAssertNil(state.presentedError)
    }

    func testNativeFilesReadRetriesWhenItsWorkspaceCaptureWasSuperseded() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let original = state.currentDocument
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        let read = HeldFilesSelectionRead()
        defer { read.release() }
        let deferral = FilesSelectionDeferral()
        deferral.beforeFileRead = { read.holdFirstRead() }
        deferral.open(id: bID, requestingEditorFocus: false, pickWindow: nil, appState: state) {}
        try await waitUntil("file read is held") { read.isHeld }
        let generation = state.workspaceGeneration
        state.scheduleWorkspaceReload(root: fixture.root, selectFirstIfNeeded: false, errorTitle: "Reload")
        try await waitUntil("new workspace capture installs during the old file read") {
            state.workspaceGeneration > generation
                && state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        XCTAssertTrue(state.currentDocument === original)
        read.release()
        try await waitUntil("pick retries against the installed capture") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md" && deferral.pendingID == nil
        }
        XCTAssertEqual(state.workspaceTree?.selectedNodeID, bID)
        XCTAssertEqual(deferral.openAttempts.filter { $0.id == bID && $0.landed }.count, 1)
        XCTAssertNil(state.presentedError)
    }

    func testNativeFilesPreparedReadCannotOverwriteANewerCachedDiskObservation() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let aID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" }?.id)
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))
        let cached = state.currentDocument
        XCTAssertTrue(state.selectWorkspaceNode(id: aID, requestingEditorFocus: false))
        let original = state.currentDocument
        let read = try await state.prepareWorkspaceNodeSelection(id: bID)
        let prepared = try XCTUnwrap(read)
        let destination = fixture.root.appendingPathComponent("b.md")
        try "newer disk beta".write(to: destination, atomically: false, encoding: .utf8)
        state.handleExternalChange(for: cached)
        try await waitUntil("cached session accepts a newer real disk observation") {
            cached.text == "newer disk beta" && !cached.isDirty
        }
        XCTAssertFalse(try state.commitWorkspaceNodeSelection(prepared, requestingEditorFocus: false))
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(cached.text, "newer disk beta")
        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))
        XCTAssertTrue(state.currentDocument === cached)
        XCTAssertEqual(state.currentDocument.text, "newer disk beta")
        XCTAssertNil(state.presentedError)
    }

    func testNativeFilesPreparedReadCannotUndoACompletedBackgroundSave() async throws {
        let fixture = try await makeReadyFilesSwitchFixture()
        let state = fixture.appState
        let aID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "a.md" }?.id)
        let bID = try XCTUnwrap(state.workspaceTree?.root.children.first { $0.name == "b.md" }?.id)
        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))
        let cached = state.currentDocument
        state.applyDocumentText("saved beta", to: cached)
        XCTAssertTrue(state.selectWorkspaceNode(id: aID, requestingEditorFocus: false))
        let original = state.currentDocument
        let read = try await state.prepareWorkspaceNodeSelection(id: bID)
        let prepared = try XCTUnwrap(read)
        let version = cached.version
        try state.save(session: cached)
        XCTAssertEqual(cached.version, version, "Saving does not advance the source revision")
        XCTAssertFalse(cached.isDirty)
        XCTAssertFalse(try state.commitWorkspaceNodeSelection(prepared, requestingEditorFocus: false))
        XCTAssertTrue(state.currentDocument === original)
        XCTAssertEqual(cached.text, "saved beta")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("b.md"), encoding: .utf8),
                       "saved beta")
        XCTAssertTrue(state.selectWorkspaceNode(id: bID, requestingEditorFocus: false))
        XCTAssertTrue(state.currentDocument === cached)
        XCTAssertEqual(state.currentDocument.text, "saved beta")
        XCTAssertNil(state.presentedError)
    }

    private func makeReadyFilesSwitchFixture() async throws -> WorkspaceFixture {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "alpha", "b.md": "beta", "c.md": "gamma"])
        let state = fixture.appState
        addTeardownBlock { @MainActor in
            let tasks = self.activeTasks(in: state)
            tasks.forEach { $0.cancel() }
            state.closeWorkspace()
            for task in tasks {
                await task.value
            }
            fixture.cleanUp()
        }
        state.openExternalFile(fixture.root)
        try await waitUntil("workspace capture installs") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
                && state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        state.workspaceWatcher?.stop()
        return fixture
    }
}

private final class HeldFilesSelectionRead: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var readCount = 0
    private var held = false
    private var exited = false
    private var mainThread = false

    var isHeld: Bool {
        lock.withLock { held }
    }

    var didExit: Bool {
        lock.withLock { exited }
    }

    var ranOnMainThread: Bool {
        lock.withLock { mainThread }
    }

    func holdFirstRead() {
        let shouldHold = lock.withLock {
            readCount += 1
            guard readCount == 1 else { return false }
            held = true
            mainThread = Thread.isMainThread
            return true
        }
        guard shouldHold else { return }
        _ = gate.wait(timeout: .now() + 5)
        lock.withLock {
            held = false
            exited = true
        }
    }

    func release() {
        gate.signal()
    }
}
