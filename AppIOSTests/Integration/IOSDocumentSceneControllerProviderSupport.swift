import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
final class IOSSceneControllerLease: IOSWorkspaceAccessLease {
    let grant: IOSWorkspaceGrant
    private(set) var isReleased = false
    init(grant: IOSWorkspaceGrant) {
        self.grant = grant
    }

    func release() {
        isReleased = true
    }
}

@MainActor
final class IOSSceneControllerWorkspaceDouble: IOSWorkspaceAccessProviding {
    var selected: [(URL, IOSWorkspaceScope)] = []
    var grants: [IOSWorkspaceIdentity: IOSWorkspaceGrant] = [:]
    var invalidated: [IOSWorkspaceIdentity] = []
    var leases: [IOSSceneControllerLease] = []
    var observations: [(IOSReloadRelayObservation, @MainActor (IOSWorkspaceEvent) -> Void)] = []
    var directoryPaths = ["first.md", "second.md"]

    func open(selectedURL: URL, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        selected.append((selectedURL, scope))
        let grant = IOSWorkspaceGrant(
            workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), rootURL: selectedURL,
            accessGeneration: 1, scope: scope
        )
        grants[grant.workspaceID] = grant
        return grant
    }

    func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        guard grants[grant.workspaceID]?.accessGeneration == grant.accessGeneration,
              !invalidated.contains(grant.workspaceID) else { throw IOSWorkspaceFailure.grantChanged }
        let lease = IOSSceneControllerLease(grant: grant)
        leases.append(lease)
        return lease
    }

    func refresh(_ grant: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        let paths = grant.scope == .singleFile ? [grant.rootURL.lastPathComponent] : directoryPaths
        let entries = paths.map { path in
            IOSWorkspaceEntry(
                id: UUID(), location: IOSFileLocation(
                    workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
                    relativePath: path,
                    fileURL: grant.scope == .singleFile ? grant.rootURL : grant.rootURL.appendingPathComponent(path),
                    resourceID: nil
                ), kind: .document(.markdown), availability: .available(canWrite: true), children: []
            )
        }
        return IOSWorkspaceSnapshot(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
            requestID: UUID(), entries: entries
        )
    }

    func invalidate(_ identity: IOSWorkspaceIdentity) -> UInt64 {
        invalidated.append(identity)
        let generation = (grants[identity]?.accessGeneration ?? 0) + 1
        emit(.invalidated(workspaceID: identity, generation: generation))
        return generation
    }

    func emit(_ event: IOSWorkspaceEvent) {
        for (token, handler) in observations where !token.isCancelled {
            handler(event)
        }
    }

    func observe(_ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation {
        let token = IOSReloadRelayObservation()
        observations.append((token, handler))
        return token
    }

    func restore(bookmark _: Data, scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        throw IOSWorkspaceFailure.unavailable
    }

    func snapshot(for _: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        nil
    }
}

@MainActor
final class IOSSceneControllerPreviewDouble: IOSPreviewControlling {
    var renders: [(IOSDocumentIdentity, Int, PreviewAssetAccessContext?)] = []
    func render(_ snapshot: DocumentSnapshot, identity: IOSDocumentIdentity, assetAccess: PreviewAssetAccessContext?) {
        renders.append((identity, snapshot.version, assetAccess))
    }

    func setRemoteImagesAllowed(_: Bool) {}
    func scrollToLine(_: Int) {}
    func invalidate() {}
    func observe(_: @escaping @MainActor (IOSPreviewEvent) -> Void) -> any IOSObservation {
        IOSReloadRelayObservation()
    }
}

private actor IOSSceneControllerAssetDouble: IOSWorkspaceAssetWriting {
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

@MainActor
struct IOSSceneControllerFixture {
    let store = IOSSceneControllerStoreDouble()
    let workspace = IOSSceneControllerWorkspaceDouble()
    let editor = IOSReloadRelayEditorDouble()
    let preview = IOSSceneControllerPreviewDouble()
    let controller: IOSDocumentSceneController
    let selectedURL = URL(fileURLWithPath: "/synthetic/public.md")

    init() {
        controller = IOSDocumentSceneController(
            documents: store, workspace: workspace, editor: editor, preview: preview,
            assets: IOSSceneControllerAssetDouble(), assetContext: { _ in nil }
        )
    }
}
