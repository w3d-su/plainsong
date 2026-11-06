import Foundation
import WorkspaceKitIOS

/// App-only seam for presentation and controlled tests, not a new grant provider.
/// Production conformance always returns this same access service.
@MainActor
protocol IOSRecentWorkspaceAccess: AnyObject {
    var workspaceProvider: any IOSWorkspaceAccessProviding { get }
    func recentItems() -> [IOSRecentWorkspaceItem]
    func restoreRecent(recordID: UUID) async throws -> IOSWorkspaceGrant
    func removeRecent(recordID: UUID)
}

extension IOSWorkspaceAccessService: IOSRecentWorkspaceAccess {
    var workspaceProvider: any IOSWorkspaceAccessProviding {
        self
    }
}
