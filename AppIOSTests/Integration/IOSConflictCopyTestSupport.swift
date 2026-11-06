import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
struct IOSConflictCopyTestRequest {
    let identity: IOSDocumentIdentity
    let location: IOSFileLocation
    let lease: any IOSWorkspaceAccessLease
}

@MainActor
final class IOSConflictCopyStoreDouble: IOSDocumentStore {
    let base = IOSSceneControllerStoreDouble()
    var copyLatch: IOSSceneControllerLatch?
    var copyError: Error?
    var onCopy: (() -> Void)?
    var copyRequests: [IOSConflictCopyTestRequest] = []
    var createdCopies: [(IOSFileLocation, String)] = []
    var resolutionLatch: IOSSceneControllerLatch?
    var resolutionRequests = 0

    func open(_ location: IOSFileLocation, lease: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle {
        try await base.open(location, lease: lease)
    }

    func create(at location: IOSFileLocation, initialText: String,
                lease: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle
    {
        try await base.create(at: location, initialText: initialText, lease: lease)
    }

    func close(_ identity: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome {
        try await base.close(identity)
    }

    func save(_ identity: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        if case .conflict = base.states[identity] {
            throw IOSDocumentFailure.conflict
        }
        return try await base.save(identity)
    }

    func saveCopy(_ identity: IOSDocumentIdentity, destination: IOSFileLocation,
                  lease: any IOSWorkspaceAccessLease) async throws -> IOSSaveAcknowledgement
    {
        guard let handle = base.handles[identity] else { throw IOSDocumentFailure.unavailable }
        let text = handle.session.text
        let version = handle.session.version
        copyRequests.append(IOSConflictCopyTestRequest(identity: identity, location: destination, lease: lease))
        onCopy?()
        // Intentionally ignore cancellation until released, modeling a provider
        // operation whose scope must remain held while its callback drains.
        await copyLatch?.wait()
        if let copyError {
            throw copyError
        }
        createdCopies.append((destination, text))
        guard version == handle.session.version, text.utf8.elementsEqual(handle.session.text.utf8) else {
            throw IOSDocumentFailure.sourceChanged
        }
        let receipt = IOSSaveAcknowledgement(
            operationID: UUID(), revision: IOSDocumentRevision(documentID: identity, version: version),
            savedText: text, location: destination
        )
        base.emit(.saveCompleted(receipt))
        return receipt
    }

    func resolveExternal(_: IOSDocumentIdentity, choice _: IOSExternalResolution) async throws {
        resolutionRequests += 1
        await resolutionLatch?.wait()
    }

    func state(for identity: IOSDocumentIdentity) -> IOSDocumentState? {
        base.state(for: identity)
    }

    func snapshot(for identity: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot? {
        base.snapshot(for: identity)
    }

    func observe(_ handler: @escaping @MainActor (IOSDocumentEvent) -> Void) -> any IOSObservation {
        base
            .observe(handler)
    }

    func acknowledgeExternalReload(operationID _: UUID, outcome _: IOSDocumentReloadOutcome) {}
    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        []
    }
}

@MainActor
final class IOSConflictCopyWorkspaceDouble: IOSWorkspaceAccessProviding {
    let base = IOSSceneControllerWorkspaceDouble()
    var openLatch: IOSSceneControllerLatch?
    var refreshLatch: IOSSceneControllerLatch?
    var onDestinationOpen: ((IOSWorkspaceGrant) -> Void)?
    var onDestinationRefresh: ((IOSWorkspaceGrant) -> Void)?
    var destinationGrant: IOSWorkspaceGrant?
    let destinationURL = URL(fileURLWithPath: "/synthetic/destination", isDirectory: true)

    func open(selectedURL: URL, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        let grant = try await base.open(selectedURL: selectedURL, scope: scope)
        if selectedURL == destinationURL {
            destinationGrant = grant
            onDestinationOpen?(grant)
            await openLatch?.wait()
        }
        return grant
    }

    func refresh(_ grant: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        if grant.workspaceID == destinationGrant?.workspaceID {
            onDestinationRefresh?(grant)
            await refreshLatch?.wait()
        }
        return try await base.refresh(grant)
    }

    func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        try base
            .acquireLease(for: grant)
    }

    func invalidate(_ identity: IOSWorkspaceIdentity) -> UInt64 {
        base.invalidate(identity)
    }

    func snapshot(for identity: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        base.snapshot(for: identity)
    }

    func observe(_ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation {
        base
            .observe(handler)
    }

    func restore(bookmark _: Data, scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        throw IOSWorkspaceFailure.unavailable
    }
}

@MainActor
struct IOSConflictCopyFixture {
    let documents = IOSConflictCopyStoreDouble()
    let workspace = IOSConflictCopyWorkspaceDouble()
    let editor = IOSReloadRelayEditorDouble()
    let preview = IOSSceneControllerPreviewDouble()
    let controller: IOSDocumentSceneController
    let copy: IOSConflictCopyCoordinator

    init() {
        let controller = IOSDocumentSceneController(
            documents: documents, workspace: workspace, editor: editor, preview: preview,
            assets: IOSConflictCopyUnusedAssets(), assetContext: { _ in nil }
        )
        self.controller = controller
        copy = IOSConflictCopyCoordinator(controller: controller)
    }

    func openConflict() async throws -> IOSDocumentHandle {
        try await controller.openPickedURL(URL(fileURLWithPath: "/synthetic/original.md"), scope: .singleFile)
        guard let handle = controller.handle else { throw IOSDocumentFailure.unavailable }
        handle.session.replaceTextFromAuthorizedEditor("local N 繁中 👩🏽‍💻")
        let recovery = IOSRecoveryReceipt(
            operationID: UUID(), revision: IOSDocumentRevision(
                documentID: handle.identity,
                version: handle.session.version
            ),
            recordID: UUID()
        )
        documents.base.states[handle.identity] = .conflict(
            accessGeneration: handle.location.accessGeneration,
            recovery: recovery
        )
        controller.updateEditorAccess()
        return handle
    }

    func prepare(filename: String = "Original Copy.md") throws -> IOSConflictCopyPickerRequest {
        guard copy.requestSaveCopy(), let draft = copy.draft,
              let picker = copy.requestFolderPicker(draftID: draft.id, filename: filename)
        else { throw IOSDocumentFailure.unavailable }
        return picker
    }

    func stop() {
        controller.renderTask?.cancel()
        controller.documentObservation?.cancel()
        controller.workspaceObservation?.cancel()
        controller.editorObservation?.cancel()
        controller.previewObservation?.cancel()
        controller.reloadRelay.detach()
    }
}

actor IOSConflictCopyUnusedAssets: IOSWorkspaceAssetWriting {
    func stage(_: IOSImageAssetRequest, grant _: IOSWorkspaceGrant) async throws -> IOSStagedImageAsset {
        throw IOSAssetStageFailure.failed(.unavailable)
    }

    func validate(_: IOSStagedImageAsset) async throws {
        throw IOSWorkspaceFailure.unavailable
    }

    func commit(_ asset: IOSStagedImageAsset) async -> IOSAssetCommitOutcome {
        .retained(receipt(asset))
    }

    func rollback(_ asset: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome {
        .retained(receipt(asset))
    }

    private func receipt(_ asset: IOSStagedImageAsset) -> IOSAssetRecoveryReceipt {
        IOSAssetRecoveryReceipt(
            operationID: asset.operationID, targetLocation: asset.targetLocation,
            ownershipToken: asset.ownershipToken, reason: .indeterminate
        )
    }
}
