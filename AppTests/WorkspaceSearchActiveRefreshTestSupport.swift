import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

struct ActiveSearchRefreshFixture {
    let appState: AppState
    let rootURL: URL
    let snapshot: WorkspaceFileSnapshot
}

enum ActiveSearchRefreshTestError: Error {
    case timedOut
}

@MainActor
final class ActiveSearchRefreshProvider: WorkspaceSearchStreamProviding {
    private(set) var requests: [WorkspaceSearchRequest] = []
    private(set) var terminatedIndices: Set<Int> = []
    private var continuations: [AsyncStream<WorkspaceSearchEvent>.Continuation] = []

    func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent> {
        let pair = AsyncStream<WorkspaceSearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let index = requests.count
        requests.append(request)
        continuations.append(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminatedIndices.insert(index)
            }
        }
        return pair.stream
    }

    func yield(_ event: WorkspaceSearchEvent, to index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(_ index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }
}

actor ActiveSearchRefreshScanner: WorkspaceDirectoryScanning {
    private struct PendingRequest {
        let rootAuthority: WorkspaceFileSystemRootAuthority
        var continuation: CheckedContinuation<WorkspaceFileSnapshot, Error>?
    }

    private var requests: [PendingRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        let rootAuthority = try await WorkspaceFileSystemRootAuthority.capture(rootURL: root)
        let snapshot = try await withCheckedThrowingContinuation { continuation in
            requests.append(PendingRequest(
                rootAuthority: rootAuthority,
                continuation: continuation
            ))
            let readyWaiters = waiters
            waiters.removeAll()
            readyWaiters.forEach { $0.resume() }
        }
        return WorkspaceDirectorySnapshotCapture(
            snapshot: snapshot,
            rootAuthority: rootAuthority
        )
    }

    func waitForRequestCount(_ count: Int) async {
        while requests.count < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func rootAuthority(at index: Int) -> WorkspaceFileSystemRootAuthority? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].rootAuthority
    }

    func complete(_ index: Int, with snapshot: WorkspaceFileSnapshot) {
        guard requests.indices.contains(index),
              let continuation = requests[index].continuation
        else {
            return
        }
        requests[index].continuation = nil
        continuation.resume(returning: snapshot)
    }

    func fail(_ index: Int, with error: any Error) {
        guard requests.indices.contains(index),
              let continuation = requests[index].continuation
        else {
            return
        }
        requests[index].continuation = nil
        continuation.resume(throwing: error)
    }
}

@MainActor
func makeActiveSearchRefreshFixture(
    provider: ActiveSearchRefreshProvider,
    scanner: any WorkspaceDirectoryScanning,
    files: [String: String],
    currentPath: String? = nil,
    debounceNanoseconds: UInt64 = 0
) throws -> ActiveSearchRefreshFixture {
    let rootURL = try makeActiveSearchRefreshTemporaryDirectory()
    for (path, text) in files {
        let fileURL = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let snapshot = activeSearchRefreshSnapshot(paths: files.keys, rootURL: rootURL)
    let currentDocument: DocumentSession
    if let currentPath, let text = files[currentPath] {
        let fileURL = rootURL.appendingPathComponent(currentPath)
        currentDocument = DocumentSession(
            text: text,
            url: fileURL,
            fileKind: FileKind(url: fileURL)
        )
    } else {
        currentDocument = DocumentSession()
    }
    let appState = AppState(
        currentDocument: currentDocument,
        directoryScanner: scanner,
        workspaceSearchStreamProvider: provider,
        workspaceSearchDebounceNanoseconds: debounceNanoseconds,
        shouldRestoreLastOpenedFile: false
    )
    appState.workspaceRootURL = rootURL
    appState.workspaceSnapshot = snapshot
    let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
    appState.workspaceSearchRootAuthority = rootAuthority
    appState.workspaceGeneration = 1
    appState.workspaceInstalledCaptureGeneration = 1
    appState.workspaceTree = WorkspaceFileTree.reconcile(
        previous: nil,
        snapshot: snapshot,
        options: .init(showAllFiles: false)
    )
    if currentDocument.fileURL != nil {
        try retainActiveSearchRefreshSession(currentDocument, in: appState)
    }
    return ActiveSearchRefreshFixture(appState: appState, rootURL: rootURL, snapshot: snapshot)
}

@MainActor
@discardableResult
func addActiveSearchRefreshWarmSession(
    path: String,
    text: String,
    to fixture: ActiveSearchRefreshFixture
) throws -> DocumentSession {
    let fileURL = fixture.rootURL.appendingPathComponent(path)
    let session = DocumentSession(text: text, url: fileURL, fileKind: FileKind(url: fileURL))
    try retainActiveSearchRefreshSession(session, in: fixture.appState)
    return session
}

@MainActor
func retainActiveSearchRefreshSession(
    _ session: DocumentSession,
    in appState: AppState
) throws {
    let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
    let fileURL = try XCTUnwrap(session.fileURL)
    let location = try rootAuthority.canonicalizedLocation(forFileURL: fileURL)
    let loaded = try MarkdownFileStore().loadResult(at: location)
    appState.adoptAnchoredFileBinding(
        AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        ),
        for: session
    )
    appState.sessionCache[location.fileURL] = session
    _ = appState.sessionPolicy.access(location.fileURL, isDirty: session.isDirty)
}

@MainActor
func cleanUpActiveSearchRefreshFixture(_ fixture: ActiveSearchRefreshFixture) {
    fixture.appState.autosaveTask?.cancel()
    fixture.appState.statisticsTask?.cancel()
    fixture.appState.completionWorkspaceTask?.cancel()
    fixture.appState.teardownWorkspaceSearch()
    fixture.appState.workspaceWatcher?.stop()
    try? FileManager.default.removeItem(at: fixture.rootURL)
}

@MainActor
func waitForActiveSearchRefresh(
    _ description: String,
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
    while !condition() {
        if clock.now >= deadline {
            XCTFail("Timed out waiting for \(description)")
            throw ActiveSearchRefreshTestError.timedOut
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

func activeSearchRefreshSnapshot(
    paths: some Sequence<String>,
    rootURL: URL
) -> WorkspaceFileSnapshot {
    WorkspaceFileSnapshot(entries: paths.sorted().map { path in
        let url = rootURL.appendingPathComponent(path)
        return WorkspaceFileSnapshot.Entry(
            relativePath: path,
            kind: WorkspaceFileKind(url: url, isDirectory: false),
            identity: "id:\(path)",
            contentModificationDate: nil
        )
    })
}

func activeSearchRefreshContext(_ request: WorkspaceSearchRequest) -> WorkspaceSearchContext {
    WorkspaceSearchContext(
        rootIdentity: request.rootIdentity,
        workspaceGeneration: request.workspaceGeneration,
        queryGeneration: request.queryGeneration
    )
}

func activeSearchRefreshResult(path: String, text: String, needle: String) -> WorkspaceSearchFileResult {
    let range = (text as NSString).range(of: needle)
    return WorkspaceSearchFileResult(
        relativePath: path,
        contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
        matches: [TextSearchMatch(
            range: range,
            line: 1,
            preview: text,
            previewMatchRange: range
        )],
        isTruncated: false
    )
}

func makeActiveSearchRefreshTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkspaceSearchActiveRefreshTests")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
}
