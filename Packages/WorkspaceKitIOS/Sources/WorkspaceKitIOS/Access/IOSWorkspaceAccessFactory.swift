import Foundation

@MainActor
public enum IOSWorkspaceAccessFactory {
    /// Production Files / iCloud service. Lane 13 injects this after M0; it does not compose the app.
    public static func makeProduction(
        recents: UserDefaults = .standard,
        recentKey: String = "Plainsong.IOSRecentWorkspaceGrants"
    ) -> IOSWorkspaceAccessService {
        IOSWorkspaceAccessService(ports: IOSSystemAccessPorts.make(recents: recents, recentKey: recentKey))
    }
}
