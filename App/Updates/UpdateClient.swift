import Combine
import Foundation

/// Updater surface the Settings toggles and the Check for Updates menu bind to.
/// Production uses Sparkle; tests use a stand-in that never opens a connection.
@MainActor
protocol UpdateClient: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var receivesBetaUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    var automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var automaticallyDownloadsUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var receivesBetaUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }

    func checkForUpdates()
    func allowedChannels() -> Set<String>
}

/// Settings › General bindings. Writes go to the client; published values follow
/// the client, including changes Sparkle makes from its own permission prompt.
@MainActor
final class UpdateSettingsModel: ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var automaticallyDownloadsUpdates: Bool
    @Published private(set) var receivesBetaUpdates: Bool

    private let client: any UpdateClient
    private var cancellables: Set<AnyCancellable> = []

    init(client: any UpdateClient) {
        self.client = client
        automaticallyChecksForUpdates = client.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = client.automaticallyDownloadsUpdates
        receivesBetaUpdates = client.receivesBetaUpdates
        client.automaticallyChecksForUpdatesPublisher
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)
        client.automaticallyDownloadsUpdatesPublisher
            .sink { [weak self] value in
                self?.automaticallyDownloadsUpdates = value
            }
            .store(in: &cancellables)
        client.receivesBetaUpdatesPublisher
            .sink { [weak self] value in
                self?.receivesBetaUpdates = value
            }
            .store(in: &cancellables)
    }

    func setAutomaticallyChecksForUpdates(_ isOn: Bool) {
        client.automaticallyChecksForUpdates = isOn
    }

    func setAutomaticallyDownloadsUpdates(_ isOn: Bool) {
        client.automaticallyDownloadsUpdates = isOn
    }

    func setReceivesBetaUpdates(_ isOn: Bool) {
        client.receivesBetaUpdates = isOn
    }

    var allowedChannels: Set<String> {
        client.allowedChannels()
    }
}

/// Menu enablement for Plainsong › Check for Updates…. Mirrors Sparkle's SwiftUI
/// sample: the item is disabled unless `canCheckForUpdates` is true.
@MainActor
final class CheckForUpdatesModel: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool

    private let client: any UpdateClient
    private var cancellable: AnyCancellable?

    init(client: any UpdateClient) {
        self.client = client
        canCheckForUpdates = client.canCheckForUpdates
        cancellable = client.canCheckForUpdatesPublisher.sink { [weak self] value in
            self?.canCheckForUpdates = value
        }
    }

    func checkForUpdates() {
        client.checkForUpdates()
    }
}
