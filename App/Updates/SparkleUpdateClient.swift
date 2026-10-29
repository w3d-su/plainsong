import Combine
import Foundation
import Sparkle

/// Keeps the beta-channel choice and answers Sparkle's `allowedChannels(for:)`.
/// Held strongly by `SparkleUpdateClient` because Sparkle keeps the delegate weakly.
final class PlainsongUpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    static let defaultsKey = "PlainsongReceivesBetaUpdates"

    private let defaults: UserDefaults
    private let betaUpdates: CurrentValueSubject<Bool, Never>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        betaUpdates = CurrentValueSubject(defaults.bool(forKey: Self.defaultsKey))
        super.init()
    }

    var receivesBetaUpdates: Bool {
        get { betaUpdates.value }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
            betaUpdates.send(newValue)
        }
    }

    var receivesBetaUpdatesPublisher: AnyPublisher<Bool, Never> {
        betaUpdates.eraseToAnyPublisher()
    }

    func allowedChannels() -> Set<String> {
        UpdateChannelPolicy.allowedChannels(receivesBetaUpdates: receivesBetaUpdates)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        _ = updater
        return allowedChannels()
    }

    /// Bundle `SUFeedURL`. Sparkle 2.10.0 treats a nil delegate result as "fall
    /// back to user defaults" (`-[SPUUpdater retrieveFeedURL:]`). An empty string
    /// does not fall back, so a missing key stays empty instead of becoming a
    /// `defaults write` override.
    static func feedURLString(in bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        _ = updater
        return Self.feedURLString(in: .main)
    }
}

/// The only type that constructs `SPUStandardUpdaterController`. Callers must not
/// create it when `PLAINSONG_UPDATES_ENABLED` is NO.
@MainActor
final class SparkleUpdateClient: UpdateClient {
    /// Incremented when the controller is constructed. `startUpdater` can still
    /// fail afterwards (U1's empty EdDSA key does); this is not a scheduled check.
    private(set) static var constructedCount = 0

    private let controller: SPUStandardUpdaterController
    private let channels: PlainsongUpdateChannelDelegate
    private let updater: SPUUpdater

    init(defaults: UserDefaults = .standard) {
        let channels = PlainsongUpdateChannelDelegate(defaults: defaults)
        self.channels = channels
        // startingUpdater: true is the full Sparkle path (second-launch prompt,
        // scheduled checks). U1 never reaches this initializer by default.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channels,
            userDriverDelegate: nil
        )
        updater = controller.updater
        // Remove a legacy `defaults write … SUFeedURL` before a later cycle.
        // The delegate already overrides it for this start.
        _ = updater.clearFeedURLFromUserDefaults()
        Self.constructedCount += 1
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var receivesBetaUpdates: Bool {
        get { channels.receivesBetaUpdates }
        set { channels.receivesBetaUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never> {
        updater.publisher(for: \.automaticallyChecksForUpdates).eraseToAnyPublisher()
    }

    var automaticallyDownloadsUpdatesPublisher: AnyPublisher<Bool, Never> {
        updater.publisher(for: \.automaticallyDownloadsUpdates).eraseToAnyPublisher()
    }

    var receivesBetaUpdatesPublisher: AnyPublisher<Bool, Never> {
        channels.receivesBetaUpdatesPublisher
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func allowedChannels() -> Set<String> {
        channels.allowedChannels()
    }
}
