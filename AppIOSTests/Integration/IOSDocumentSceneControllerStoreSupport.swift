import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
final class IOSSceneControllerLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class IOSSceneControllerStoreDouble: IOSDocumentStore {
    var initialText = "original"
    var handles: [IOSDocumentIdentity: IOSDocumentHandle] = [:]
    var states: [IOSDocumentIdentity: IOSDocumentState] = [:]
    var opened: [IOSFileLocation] = []
    var closed: [IOSDocumentIdentity] = []
    var saved: [IOSSaveAcknowledgement] = []
    var openLatch: IOSSceneControllerLatch?
    var openFailure: IOSDocumentFailure?
    var closeLatch: IOSSceneControllerLatch?
    var saveLatch: IOSSceneControllerLatch?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?
    var closeOutcome: IOSDocumentCloseOutcome = .closed
    var createFailure: IOSDocumentFailure?
    var observations: [(IOSReloadRelayObservation, @MainActor (IOSDocumentEvent) -> Void)] = []
    var flushCount = 0

    func open(_ location: IOSFileLocation, lease _: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle {
        opened.append(location)
        let failure = openFailure
        onOpen?()
        await openLatch?.wait()
        if let failure {
            throw failure
        }
        let handle = IOSDocumentHandle(
            identity: IOSDocumentIdentity(rawValue: UUID()),
            session: DocumentSession(text: initialText, url: location.fileURL), location: location
        )
        handles[handle.identity] = handle
        states[handle.identity] = .ready(canWrite: true, accessGeneration: location.accessGeneration)
        return handle
    }

    func create(at location: IOSFileLocation, initialText: String,
                lease: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle
    {
        if let createFailure {
            throw createFailure
        }
        let handle = try await open(location, lease: lease)
        handle.session.replaceTextFromAuthorizedEditor(initialText)
        return handle
    }

    func save(_ identity: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        guard let handle = handles[identity] else { throw IOSDocumentFailure.unavailable }
        let receipt = IOSSaveAcknowledgement(
            operationID: UUID(), revision: IOSDocumentRevision(documentID: identity, version: handle.session.version),
            savedText: handle.session.text, location: handle.location
        )
        saved.append(receipt)
        states[identity] = .saving(
            canWrite: true, accessGeneration: handle.location.accessGeneration, operationID: receipt.operationID
        )
        emit(.stateChanged(identity: identity, location: handle.location, state: states[identity]!))
        onSave?()
        await saveLatch?.wait()
        handle.session.rebaseSavedText(to: receipt.savedText)
        states[identity] = .ready(canWrite: true, accessGeneration: handle.location.accessGeneration)
        emit(.saveCompleted(receipt))
        return receipt
    }

    func close(_ identity: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome {
        closed.append(identity)
        onClose?()
        await closeLatch?.wait()
        if case .closed = closeOutcome {
            states[identity] = .closed(accessGeneration: handles[identity]?.location.accessGeneration ?? 1)
            emit(.closed(identity))
            handles[identity] = nil
        }
        return closeOutcome
    }

    func emitReady(for identity: IOSDocumentIdentity, generation: UInt64) {
        guard let handle = handles[identity] else { return }
        states[identity] = .ready(canWrite: true, accessGeneration: generation)
        emit(.stateChanged(identity: identity, location: handle.location, state: states[identity]!))
    }

    func emit(_ event: IOSDocumentEvent) {
        for (token, handler) in observations where !token.isCancelled {
            handler(event)
        }
    }

    func state(for identity: IOSDocumentIdentity) -> IOSDocumentState? {
        states[identity]
    }

    func snapshot(for identity: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot? {
        guard let handle = handles[identity], let state = states[identity] else { return nil }
        return IOSStoredDocumentSnapshot(
            revision: IOSDocumentRevision(documentID: identity, version: handle.session.version),
            document: handle.session.snapshot, location: handle.location, state: state
        )
    }

    func observe(_ handler: @escaping @MainActor (IOSDocumentEvent) -> Void) -> any IOSObservation {
        let token = IOSReloadRelayObservation()
        observations.append((token, handler))
        return token
    }

    func saveCopy(_: IOSDocumentIdentity, destination _: IOSFileLocation,
                  lease _: any IOSWorkspaceAccessLease) async throws -> IOSSaveAcknowledgement
    {
        throw IOSDocumentFailure.unavailable
    }

    func resolveExternal(_: IOSDocumentIdentity, choice _: IOSExternalResolution) async throws {
        throw IOSDocumentFailure.unavailable
    }

    func acknowledgeExternalReload(operationID _: UUID, outcome _: IOSDocumentReloadOutcome) {}

    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        flushCount += 1
        return []
    }
}
