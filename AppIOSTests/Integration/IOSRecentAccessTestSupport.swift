import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
final class IOSRecentTestWorkspace: IOSWorkspaceAccessProviding {
    let base = IOSSceneControllerWorkspaceDouble()
    var refreshLatch: IOSSceneControllerLatch?
    var onRefresh: (() -> Void)?

    func open(selectedURL: URL, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        try await base.open(selectedURL: selectedURL, scope: scope)
    }

    func restore(bookmark _: Data, scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        throw IOSWorkspaceFailure.unavailable
    }

    func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        try base.acquireLease(for: grant)
    }

    func invalidate(_ identity: IOSWorkspaceIdentity) -> UInt64 {
        base.invalidate(identity)
    }

    func snapshot(for _: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        nil
    }

    func refresh(_ grant: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        onRefresh?()
        await refreshLatch?.wait()
        return try await base.refresh(grant)
    }

    func observe(_ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation {
        base.observe(handler)
    }
}

@MainActor
final class IOSRecentTestAccess: IOSRecentWorkspaceAccess {
    let workspace = IOSRecentTestWorkspace()
    var workspaceProvider: any IOSWorkspaceAccessProviding {
        workspace
    }

    var entries: [IOSRecentWorkspaceItem] = []
    var urls: [UUID: URL] = [:]
    var restoreCalls: [UUID] = []
    var removed: [UUID] = []
    var restoreLatch: IOSSceneControllerLatch?
    var onRestore: (() -> Void)?
    var restoredGrant: IOSWorkspaceGrant?

    func add(scope: IOSWorkspaceScope, status: IOSRecentWorkspaceStatus = .available) -> UUID {
        let id = UUID()
        entries.append(IOSRecentWorkspaceItem(recordID: id, displayName: "../display is not authority",
                                              scope: scope, openedAt: Date(timeIntervalSince1970: 10),
                                              providerIdentity: nil, status: status))
        urls[id] = URL(fileURLWithPath: scope == .directory ? "/synthetic/folder" : "/synthetic/\(id.uuidString).md")
        return id
    }

    func recentItems() -> [IOSRecentWorkspaceItem] {
        entries
    }

    func removeRecent(recordID: UUID) {
        removed.append(recordID)
        entries.removeAll { $0.recordID == recordID }
    }

    func restoreRecent(recordID: UUID) async throws -> IOSWorkspaceGrant {
        guard let item = entries.first(where: { $0.recordID == recordID }), let url = urls[recordID] else {
            throw IOSWorkspaceFailure.notFound
        }
        restoreCalls.append(recordID)
        let grant = IOSWorkspaceGrant(workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), rootURL: url,
                                      accessGeneration: 1, scope: item.scope)
        workspace.base.grants[grant.workspaceID] = grant
        restoredGrant = grant
        onRestore?()
        await restoreLatch?.wait() // Intentionally returns after cancellation for late-result tests.
        return grant
    }
}

@MainActor
struct IOSRecentSceneFixture {
    let access = IOSRecentTestAccess()
    let store = IOSSceneControllerStoreDouble()
    let editor = IOSReloadRelayEditorDouble()
    let preview = IOSSceneControllerPreviewDouble()
    let controller: IOSDocumentSceneController

    init() {
        controller = IOSDocumentSceneController(documents: store, workspace: access.workspace, editor: editor,
                                                preview: preview, assets: IOSRecentTestAssets(),
                                                assetContext: { _ in nil })
    }
}

private actor IOSRecentTestAssets: IOSWorkspaceAssetWriting {
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
        IOSAssetRecoveryReceipt(operationID: asset.operationID, targetLocation: asset.targetLocation,
                                ownershipToken: asset.ownershipToken, reason: .indeterminate)
    }
}
