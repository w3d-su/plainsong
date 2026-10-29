import Foundation

/// Decides whether this process is allowed to construct Sparkle.
/// The default build setting is NO: no controller, no scheduler, no feed request.
@MainActor
final class AppUpdateCenter: ObservableObject {
    let isEnabled: Bool
    let settingsModel: UpdateSettingsModel?
    let checkForUpdatesModel: CheckForUpdatesModel?

    private init(client: (any UpdateClient)?) {
        if let client {
            isEnabled = true
            settingsModel = UpdateSettingsModel(client: client)
            checkForUpdatesModel = CheckForUpdatesModel(client: client)
        } else {
            isEnabled = false
            settingsModel = nil
            checkForUpdatesModel = nil
        }
    }

    static func make(
        updatesEnabled: Bool,
        makeClient: () -> any UpdateClient = { SparkleUpdateClient() }
    ) -> AppUpdateCenter {
        guard updatesEnabled else {
            return AppUpdateCenter(client: nil)
        }
        return AppUpdateCenter(client: makeClient())
    }

    static func make(
        bundle: Bundle = .main,
        makeClient: () -> any UpdateClient = { SparkleUpdateClient() }
    ) -> AppUpdateCenter {
        make(
            updatesEnabled: PlainsongUpdateConfiguration.isEnabled(in: bundle),
            makeClient: makeClient
        )
    }
}
