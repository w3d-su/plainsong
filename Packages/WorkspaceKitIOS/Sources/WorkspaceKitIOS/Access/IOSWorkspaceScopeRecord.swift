import Foundation
import WorkspaceCore

@MainActor
final class IOSWorkspaceScopeRecord {
    let workspaceID: IOSWorkspaceIdentity
    let rootURL: URL
    let scope: IOSWorkspaceScope
    let rootToken: UUID
    let displayName: String
    var generation: UInt64
    var providerIdentity: Data?
    var consumerCount = 0
    var operationCount = 0
    var mustStop = false
    var stopped = false
    var sawHolder = false
    /// Set by invalidate. Scope ends only after this is set and every lease and operation has drained.
    var revoked = false
    var latestSnapshot: IOSWorkspaceSnapshot?
    var expansion: WorkspaceExpansionState?
    var latestRequestID: UUID?
    var bookmark: Data?
    var recentRecordID: UUID?

    init(
        workspaceID: IOSWorkspaceIdentity,
        rootURL: URL,
        scope: IOSWorkspaceScope,
        rootToken: UUID,
        displayName: String,
        generation: UInt64
    ) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL
        self.scope = scope
        self.rootToken = rootToken
        self.displayName = displayName
        self.generation = generation
    }

    var grant: IOSWorkspaceGrant {
        IOSWorkspaceGrant(
            workspaceID: workspaceID,
            rootURL: rootURL,
            accessGeneration: generation,
            scope: scope
        )
    }

    var isIdle: Bool {
        consumerCount == 0 && operationCount == 0
    }

    func addConsumer() {
        consumerCount += 1
        sawHolder = true
    }

    func addOperation() {
        operationCount += 1
        sawHolder = true
    }
}
