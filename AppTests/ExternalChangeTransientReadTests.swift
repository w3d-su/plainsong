import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// M2: a read racing another tool's replacement no longer detaches the document at once,
/// and a document detached while clean reattaches silently when its file comes back,
/// instead of raising Reload/Keep Mine (where Keep Mine wrote the stale copy over the new
/// file, as after a `git checkout`).
@MainActor
final class ExternalChangeTransientReadTests: XCTestCase {
    func testCleanDocumentDetachedByARemovalReloadsSilentlyWhenTheFileReturns() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)

        try FileManager.default.removeItem(at: post)
        appState.handleExternalChange(for: session)
        try await waitUntil("removal detaches") { appState.detachedSessionURLs.contains(post) }
        XCTAssertTrue(session.isDirty, "a detached editor copy is the only copy left")
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, post)
        XCTAssertFalse(appState.missingFileHasEditsBeyondLastDiskText)

        try fixture.write("disk B")
        appState.handleExternalChange(for: session)
        try await waitUntil("the returned file reloads") {
            !appState.detachedSessionURLs.contains(post) && session.text == "disk B"
        }

        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[post])
        XCTAssertNil(appState.cleanDetachedSessionRecords[ObjectIdentifier(session)])
        XCTAssertTrue(appState.canAutosave(session: session))
    }

    func testDocumentEditedAfterItsFileVanishedStillRaisesTheConflict() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)

        try FileManager.default.removeItem(at: post)
        appState.handleExternalChange(for: session)
        try await waitUntil("removal detaches") { appState.detachedSessionURLs.contains(post) }
        appState.replaceDocumentText("edited after the file vanished")
        XCTAssertTrue(appState.missingFileHasEditsBeyondLastDiskText)

        try fixture.write("disk B")
        appState.handleExternalChange(for: session)
        try await waitUntil("the returned file is a conflict") { appState.pendingExternalTexts[post] == "disk B" }

        XCTAssertEqual(session.text, "edited after the file vanished")
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, post)
    }

    func testDocumentDirtyWhenItsFileVanishedIsNeverReloadedSilently() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)
        appState.replaceDocumentText("unsaved before the removal")

        try FileManager.default.removeItem(at: post)
        appState.handleExternalChange(for: session)
        try await waitUntil("removal detaches") { appState.detachedSessionURLs.contains(post) }
        XCTAssertTrue(appState.missingFileHasEditsBeyondLastDiskText)
        XCTAssertNil(appState.cleanDetachedSessionRecords[ObjectIdentifier(session)])

        try fixture.write("disk B")
        appState.handleExternalChange(for: session)
        try await waitUntil("the returned file is a conflict") { appState.pendingExternalTexts[post] == "disk B" }
        XCTAssertEqual(session.text, "unsaved before the removal")
    }

    func testCleanDetachedDocumentReattachesWhenReopenedFromTheWorkspace() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)

        try FileManager.default.removeItem(at: post)
        appState.handleExternalChange(for: session)
        try await waitUntil("removal detaches") { appState.detachedSessionURLs.contains(post) }
        try appState.activateAnchoredFileSession(at: fixture.otherLocation)
        XCTAssertFalse(appState.shownSession === session)

        try fixture.write("disk B")
        try appState.activateAnchoredFileSession(at: fixture.location)

        XCTAssertTrue(appState.shownSession === session)
        try await waitUntil("reactivation adopts the returned file") { session.text == "disk B" }
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(appState.detachedSessionURLs.contains(post))
        XCTAssertNil(appState.pendingExternalTexts[post])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)
    }

    func testTransientReadOutcomeIsReadAgainBeforeDetaching() async throws {
        for transient in [WorkspaceCoherentFileReadOutcome.namespaceChanged, .unstable, .unreadable] {
            let fixture = try AnchoredSessionFixture(text: "disk A")
            defer { fixture.cleanUp() }
            let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)

            try fixture.write("disk B")
            fixture.reader.arm([transient])
            appState.handleExternalChange(for: session)
            XCTAssertFalse(appState.canAutosave(session: session))
            try await waitUntil("the second read reloads \(transient)") { session.text == "disk B" }

            XCTAssertEqual(fixture.reader.scriptedCallCount, 1)
            XCTAssertEqual(fixture.reader.callCount, 2)
            XCTAssertFalse(appState.detachedSessionURLs.contains(post))
            XCTAssertFalse(session.isDirty)
            XCTAssertNil(appState.missingFilePrompt)
            XCTAssertNil(appState.externalChangePrompt)
        }
    }

    func testTransientOutcomesDetachOnceTheRetriesRunOut() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)
        let attempts = AppState.externalInspectionTransientRetryDelays.count + 1
        fixture.reader.arm(Array(repeating: .unstable, count: attempts))

        appState.handleExternalChange(for: session)
        try await waitUntil("persistent instability detaches", timeout: 6) {
            appState.detachedSessionURLs.contains(post)
        }

        XCTAssertEqual(fixture.reader.callCount, attempts)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, post)
        XCTAssertNil(appState.externalDiskInspectionTasks[ObjectIdentifier(session)])
    }

    func testNewerDiskEventSupersedesAPendingRetry() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session) = (fixture.appState, fixture.session)
        fixture.reader.arm([.namespaceChanged])

        appState.handleExternalChange(for: session)
        try await waitUntil("the scripted read schedules a retry") {
            appState.externalDiskInspectionTasks[ObjectIdentifier(session)]?.transientRetry == 1
        }
        XCTAssertEqual(fixture.reader.scriptedCallCount, 1)

        try fixture.write("disk C")
        appState.handleExternalChange(for: session)
        XCTAssertEqual(appState.externalDiskInspectionTasks[ObjectIdentifier(session)]?.transientRetry, 0)
        try await waitUntil("the newer read reloads") { session.text == "disk C" }
        XCTAssertFalse(appState.detachedSessionURLs.contains(fixture.post))
    }

    func testCleanDetachRecordLivesOnlyWhileTheFileIsDetached() async throws {
        let fixture = try AnchoredSessionFixture(text: "disk A")
        defer { fixture.cleanUp() }
        let (appState, session, post) = (fixture.appState, fixture.session, fixture.post)

        try FileManager.default.removeItem(at: post)
        appState.handleExternalChange(for: session)
        try await waitUntil("removal detaches") { appState.detachedSessionURLs.contains(post) }
        XCTAssertEqual(
            appState.cleanDetachedSessionRecords[ObjectIdentifier(session)],
            CleanDetachedSessionRecord(stateURL: post, revision: session.version)
        )

        // Any path that reattaches the URL (Reload, Keep Mine, Save Copy, relocation) drops
        // the record, so a later detach cannot reuse it.
        appState.detachedSessionURLs.remove(post)
        XCTAssertNil(appState.cleanDetachedSessionRecords[ObjectIdentifier(session)])
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 4,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting: \(description)")
    }
}

/// A workspace session bound to `post.md` the way an installed workspace binds it.
@MainActor
private struct AnchoredSessionFixture {
    let root: URL
    let post: URL
    let location: WorkspaceFileSystemLocation
    let otherLocation: WorkspaceFileSystemLocation
    let session: DocumentSession
    let appState: AppState
    let reader: ScriptedCoherentFileReader

    init(text: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalChangeTransientReadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        location = try authority.location(relativePath: "post.md")
        otherLocation = try authority.location(relativePath: "other.md")
        post = location.fileURL
        try Data(text.utf8).write(to: post)
        try Data("other".utf8).write(to: otherLocation.fileURL)
        let loaded = try MarkdownFileStore().loadResult(at: location)
        session = DocumentSession(text: loaded.file.text, url: post, fileKind: .markdown, isDirty: false)
        reader = ScriptedCoherentFileReader()
        appState = AppState(
            shownSession: session,
            coherentFileReader: reader,
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.registry.sessionCache[post] = session
        _ = appState.sessionPolicy.access(post, isDirty: false)
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
    }

    /// Replaces the file the way `git checkout` and atomic saves do: a new inode.
    func write(_ text: String) throws {
        try text.write(to: post, atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        appState.autosaveTask?.cancel()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Answers the next armed outcomes, then reads the disk for real.
private final class ScriptedCoherentFileReader: WorkspaceCoherentFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private let base = WorkspaceCoherentFileReader()
    private var armed: [WorkspaceCoherentFileReadOutcome] = []
    private var calls = 0
    private var scriptedCalls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    var scriptedCallCount: Int {
        lock.withLock { scriptedCalls }
    }

    func arm(_ outcomes: [WorkspaceCoherentFileReadOutcome]) {
        lock.withLock {
            armed = outcomes
            calls = 0
            scriptedCalls = 0
        }
    }

    func readCoherentFile(at url: URL) async -> WorkspaceCoherentFileReadOutcome {
        if let scripted = nextScriptedOutcome() { return scripted }
        return await base.readCoherentFile(at: url)
    }

    func readCoherentFile(at location: WorkspaceFileSystemLocation) async -> WorkspaceCoherentFileReadOutcome {
        if let scripted = nextScriptedOutcome() { return scripted }
        return await base.readCoherentFile(at: location)
    }

    private func nextScriptedOutcome() -> WorkspaceCoherentFileReadOutcome? {
        lock.withLock {
            calls += 1
            guard !armed.isEmpty else { return nil }
            scriptedCalls += 1
            return armed.removeFirst()
        }
    }
}
