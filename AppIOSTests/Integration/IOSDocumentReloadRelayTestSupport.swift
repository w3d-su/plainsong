import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
final class IOSReloadRelayObservation: IOSObservation {
    private(set) var isCancelled = false
    func cancel() {
        isCancelled = true
    }
}

@MainActor
final class IOSReloadRelayEditorDouble: IOSSourceEditorBinding {
    var binding: IOSSourceEditorDocumentBinding
    var hasMarkedText = false
    var isBusy = false
    var isAttached = true
    var isFocused = false
    var attachCount = 0
    var installed: [IOSDocumentReloadProposal] = []
    var onInstall: (() -> Void)?
    var onCapture: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var observations: [(IOSReloadRelayObservation, @MainActor (IOSSourceEditorEvent) -> Void)] = []

    init(documentID: IOSDocumentIdentity = IOSDocumentIdentity(rawValue: UUID()), generation: UInt64 = 1) {
        binding = IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: documentID, session: DocumentSession(text: "original"),
            accessGeneration: generation, canWrite: true
        )
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        onCapture?()
        return isAttached ? snapshot : nil
    }

    var snapshot: IOSSourceEditorSnapshot {
        IOSSourceEditorSnapshot(
            bindingID: binding.bindingID,
            revision: IOSDocumentRevision(documentID: binding.identity, version: binding.session.version),
            document: binding.session.snapshot, selection: NSRange(location: 0, length: 0),
            visibleRange: NSRange(location: 0, length: binding.session.text.utf16.count),
            selectionGeneration: 1, accessGeneration: binding.accessGeneration,
            hasMarkedText: hasMarkedText, canWrite: binding.canWrite, isFocused: isFocused
        )
    }

    func installExternalReload(_ proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        installed.append(proposal)
        onEvent?("install")
        if hasMarkedText || isBusy {
            return .deferred
        }
        let capturedBinding = binding
        capturedBinding.session.replaceTextFromAuthorizedEditor(proposal.text)
        let revision = IOSDocumentRevision(
            documentID: capturedBinding.identity, version: capturedBinding.session.version
        )
        onInstall?()
        emitSnapshot()
        return .installed(revision)
    }

    func emitSnapshot() {
        let event = IOSSourceEditorEvent.snapshotChanged(snapshot)
        for (token, handler) in observations where !token.isCancelled {
            handler(event)
        }
    }

    func observe(_ handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void) -> any IOSObservation {
        let token = IOSReloadRelayObservation()
        observations.append((token, handler))
        return token
    }

    func attach(_ binding: IOSSourceEditorDocumentBinding) {
        self.binding = binding
        isAttached = true
        attachCount += 1
    }

    func detach(expected identity: IOSDocumentIdentity, bindingID: UUID) {
        guard binding.identity == identity, binding.bindingID == bindingID else { return }
        isAttached = false
        for (token, handler) in observations where !token.isCancelled {
            handler(.detached(documentID: identity, bindingID: bindingID))
        }
    }

    func updateAccess(for _: IOSDocumentIdentity, bindingID _: UUID, generation: UInt64, canWrite: Bool) {
        binding = IOSSourceEditorDocumentBinding(
            bindingID: binding.bindingID, identity: binding.identity, session: binding.session,
            accessGeneration: generation, canWrite: canWrite
        )
    }

    func apply(_: IOSAuthorizedEdit) -> IOSEditOutcome {
        .refused(.unavailable)
    }

    func reveal(_: NSRange, expected _: IOSDocumentRevision) -> Bool {
        false
    }

    func undo() {}
    func redo() {}
    func updateCommandFocus(for identity: IOSDocumentIdentity, bindingID: UUID, isFocused: Bool) {
        guard binding.identity == identity, binding.bindingID == bindingID else { return }
        self.isFocused = isFocused
    }
}

@MainActor
final class IOSReloadRelayStoreDouble: IOSDocumentStore {
    var observations: [(IOSReloadRelayObservation, @MainActor (IOSDocumentEvent) -> Void)] = []
    var acknowledgements: [(UUID, IOSDocumentReloadOutcome)] = []
    var onAcknowledge: ((UUID, IOSDocumentReloadOutcome) -> Void)?
    var onEvent: ((String) -> Void)?

    func emit(_ event: IOSDocumentEvent) {
        for (token, handler) in observations where !token.isCancelled {
            handler(event)
        }
    }

    func acknowledgeExternalReload(operationID: UUID, outcome: IOSDocumentReloadOutcome) {
        acknowledgements.append((operationID, outcome))
        onEvent?("ack")
        onAcknowledge?(operationID, outcome)
    }

    func observe(_ handler: @escaping @MainActor (IOSDocumentEvent) -> Void) -> any IOSObservation {
        let token = IOSReloadRelayObservation()
        observations.append((token, handler))
        return token
    }

    func open(_: IOSFileLocation, lease _: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle {
        throw IOSDocumentFailure.unavailable
    }

    func create(at _: IOSFileLocation, initialText _: String,
                lease _: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle
    {
        throw IOSDocumentFailure.unavailable
    }

    func save(_: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        throw IOSDocumentFailure.unavailable
    }

    func close(_: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome {
        throw IOSDocumentFailure.unavailable
    }

    func saveCopy(_: IOSDocumentIdentity, destination _: IOSFileLocation,
                  lease _: any IOSWorkspaceAccessLease) async throws -> IOSSaveAcknowledgement
    {
        throw IOSDocumentFailure.unavailable
    }

    func resolveExternal(_: IOSDocumentIdentity, choice _: IOSExternalResolution) async throws {
        throw IOSDocumentFailure.unavailable
    }

    func state(for _: IOSDocumentIdentity) -> IOSDocumentState? {
        nil
    }

    func snapshot(for _: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot? {
        nil
    }

    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        []
    }
}

@MainActor
struct IOSReloadRelayFixture {
    let store = IOSReloadRelayStoreDouble()
    let editor = IOSReloadRelayEditorDouble()
    let relay: IOSDocumentReloadRelay

    init() {
        relay = IOSDocumentReloadRelay(documents: store, editor: editor)
        attach()
    }

    func attach() {
        relay.attach(
            documentID: editor.binding.identity, bindingID: editor.binding.bindingID,
            accessGeneration: editor.binding.accessGeneration
        )
    }

    func proposal(text: String = "external", generation: UInt64? = nil) -> IOSDocumentReloadProposal {
        IOSDocumentReloadProposal(
            operationID: UUID(), capturedRevision: editor.snapshot.revision,
            accessGeneration: generation ?? editor.binding.accessGeneration,
            text: text, fileURL: URL(fileURLWithPath: "/synthetic/public.md"),
            fileKind: .markdown, statistics: TextStatistics(text: text)
        )
    }
}
