import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
@testable import WorkspaceKitIOS

@MainActor
final class IOSDeferredReloadClosePort: IOSDocumentFilePort {
    let fileURL: URL
    var closeFailure = false
    var closeLatch: IOSSceneControllerLatch?
    private(set) var closeCalls = 0
    private(set) var written: [Data] = []
    private var handler: (@MainActor (IOSDocumentFileEvent) -> Void)?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func setHandler(_ handler: (@MainActor (IOSDocumentFileEvent) -> Void)?) {
        self.handler = handler
    }

    func emitExternalChange() {
        emit(.externalChange)
    }

    func emit(_ event: IOSDocumentFileEvent) {
        handler?(event)
    }

    func open() async throws -> IOSDocumentFileOpenResult {
        IOSDocumentFileOpenResult(data: Data("original".utf8), canWrite: true)
    }

    func create(snapshot _: Data) async throws {
        throw IOSDocumentFailure.unavailable
    }

    func save(snapshot: Data, operationID _: UUID,
              completion: @escaping @MainActor (IOSDocumentFileWriteDisposition) -> Void)
    {
        written.append(snapshot)
        completion(.stored)
    }

    func close() async throws {
        closeCalls += 1
        await closeLatch?.wait()
        if closeFailure {
            throw IOSDocumentFailure.closeFailed
        }
    }
}

private struct IOSDeferredReloadCloseAccess: IOSCoordinatedFileAccess {
    func read(_ location: IOSFileLocation, lease _: any IOSWorkspaceAccessLease,
              operationID: UUID, maximumByteCount _: Int) async throws -> IOSCoordinatedRead
    {
        IOSCoordinatedRead(operationID: operationID, location: location, data: Data("foreign 繁中".utf8))
    }

    func createNewLeaf(at _: IOSFileLocation, data _: Data, lease _: any IOSWorkspaceAccessLease,
                       operationID _: UUID) async throws -> IOSCreatedLeaf
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func directorySnapshot(for _: IOSWorkspaceGrant, lease _: any IOSWorkspaceAccessLease,
                           requestID _: UUID) async throws -> IOSWorkspaceSnapshot
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func events(for _: IOSWorkspaceGrant,
                lease _: any IOSWorkspaceAccessLease) async -> AsyncStream<IOSWorkspaceEvent>
    {
        AsyncStream { $0.finish() }
    }
}

@MainActor
final class IOSDeferredReloadCloseFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: IOSUIDocumentStore
    let editor = IOSReloadRelayEditorDouble()
    let relay: IOSDocumentReloadRelay
    let port: IOSDeferredReloadClosePort
    let lease: IOSSceneControllerLease
    let location: IOSFileLocation
    private(set) var handle: IOSDocumentHandle?

    init(coordinatedAccess: (any IOSCoordinatedFileAccess)? = nil,
         recovery: (any IOSRecoveryPersisting)? = nil)
    {
        let grant = IOSWorkspaceGrant(
            workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), rootURL: directory,
            accessGeneration: 1, scope: .directory
        )
        location = IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: 1, relativePath: "note.md",
            fileURL: directory.appendingPathComponent("note.md"), resourceID: nil
        )
        port = IOSDeferredReloadClosePort(fileURL: location.fileURL)
        lease = IOSSceneControllerLease(grant: grant)
        let port = port
        store = IOSUIDocumentStore(
            coordinatedAccess: coordinatedAccess ?? IOSDeferredReloadCloseAccess(),
            recovery: recovery ?? IOSDocumentRecoveryStore(directory: directory.appendingPathComponent("recovery")),
            timing: IOSDocumentTiming(autosaveDelayNanoseconds: 60_000_000_000, backgroundFlushNanoseconds: 40_000_000),
            filePortFactory: { _ in port }
        )
        relay = IOSDocumentReloadRelay(documents: store, editor: editor)
    }

    func open() async throws -> IOSDocumentHandle {
        let handle = try await store.open(location, lease: lease)
        self.handle = handle
        editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: editor.binding.bindingID, identity: handle.identity, session: handle.session,
            accessGeneration: 1, canWrite: true
        ))
        relay.attach(documentID: handle.identity, bindingID: editor.binding.bindingID, accessGeneration: 1)
        return handle
    }

    func openWithDeferredReload() async throws -> IOSDocumentHandle {
        let handle = try await open()
        editor.hasMarkedText = true
        port.emitExternalChange()
        return handle
    }

    func removeMarkedState() {
        editor.hasMarkedText = false
        editor.emitSnapshot()
    }

    func cleanUp() async {
        relay.detach()
        port.closeLatch?.release()
        port.closeFailure = false
        if let handle, !lease.isReleased {
            _ = try? await store.close(handle.identity)
        }
        // A revoked or negatively probed entry may deliberately remain retained.
        // Its test-only observation/debounce tasks must not survive the fixture.
        for entry in store.byIdentity.values {
            entry.textTask?.cancel()
            entry.autosaveTask?.cancel()
        }
        port.setHandler(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}
