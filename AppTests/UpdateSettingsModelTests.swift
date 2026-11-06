import Combine
import Foundation
@testable import Plainsong
import XCTest

@MainActor
final class UpdateSettingsModelTests: XCTestCase {
    func testSettingsBindingsFollowTheClientInBothDirections() {
        let client = FakeUpdateClient()
        let model = UpdateSettingsModel(client: client)

        XCTAssertTrue(model.automaticallyChecksForUpdates)
        XCTAssertFalse(model.automaticallyDownloadsUpdates)
        XCTAssertFalse(model.receivesBetaUpdates)
        XCTAssertEqual(model.allowedChannels, [])

        model.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(client.automaticallyChecksForUpdates)
        XCTAssertFalse(model.automaticallyChecksForUpdates)

        client.automaticallyChecksForUpdates = true
        XCTAssertTrue(model.automaticallyChecksForUpdates)

        model.setAutomaticallyDownloadsUpdates(true)
        XCTAssertTrue(client.automaticallyDownloadsUpdates)
        XCTAssertTrue(model.automaticallyDownloadsUpdates)
        XCTAssertTrue(model.automaticallyChecksForUpdates, "download must not change checks")

        model.setReceivesBetaUpdates(true)
        XCTAssertTrue(client.receivesBetaUpdates)
        XCTAssertEqual(model.allowedChannels, ["beta"])

        model.setReceivesBetaUpdates(false)
        XCTAssertEqual(client.allowedChannels(), [])
        XCTAssertEqual(model.allowedChannels, [])
    }

    func testCheckForUpdatesMenuFollowsCanCheckForUpdates() {
        let client = FakeUpdateClient()
        let menu = CheckForUpdatesModel(client: client)
        XCTAssertTrue(menu.canCheckForUpdates)

        client.canCheckForUpdates = false
        XCTAssertFalse(menu.canCheckForUpdates)

        client.canCheckForUpdates = true
        XCTAssertTrue(menu.canCheckForUpdates)
        menu.checkForUpdates()
        XCTAssertEqual(client.checkCount, 1)
    }

    func testDisabledCenterDoesNotCreateAClient() {
        let startsBefore = SparkleUpdateClient.constructedCount
        var calls = 0
        let center = AppUpdateCenter.make(updatesEnabled: false) {
            calls += 1
            return FakeUpdateClient()
        }
        XCTAssertFalse(center.isEnabled)
        XCTAssertNil(center.settingsModel)
        XCTAssertNil(center.checkForUpdatesModel)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(SparkleUpdateClient.constructedCount, startsBefore)
    }

    func testEnabledCenterUsesTheInjectedClient() {
        let client = FakeUpdateClient()
        let center = AppUpdateCenter.make(updatesEnabled: true) { client }
        XCTAssertTrue(center.isEnabled)
        XCTAssertNotNil(center.settingsModel)
        XCTAssertNotNil(center.checkForUpdatesModel)
        center.settingsModel?.setAutomaticallyDownloadsUpdates(true)
        XCTAssertTrue(client.automaticallyDownloadsUpdates)
        XCTAssertEqual(SparkleUpdateClient.constructedCount, 0)
    }

    func testBetaDelegateDoesNotStartTheUpdater() {
        let suite = "PlainsongBeta-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not open an isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = PlainsongUpdateChannelDelegate(defaults: defaults)
        XCTAssertTrue(
            delegate.responds(to: #selector(PlainsongUpdateChannelDelegate.allowedChannels(for:)))
        )
        XCTAssertEqual(delegate.allowedChannels(), [])
        delegate.receivesBetaUpdates = true
        XCTAssertEqual(delegate.allowedChannels(), ["beta"])
        XCTAssertTrue(defaults.bool(forKey: PlainsongUpdateChannelDelegate.defaultsKey))
        XCTAssertEqual(SparkleUpdateClient.constructedCount, 0)
    }

    func testTurningOffAutomaticChecksClearsAutomaticDownload() {
        let client = FakeUpdateClient(automaticallyDownloadsUpdates: true)
        let model = UpdateSettingsModel(client: client)
        XCTAssertTrue(model.automaticallyDownloadsUpdates)

        model.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(client.automaticallyChecksForUpdates)
        XCTAssertFalse(client.automaticallyDownloadsUpdates)
        XCTAssertFalse(model.automaticallyDownloadsUpdates)

        model.setAutomaticallyDownloadsUpdates(true)
        XCTAssertFalse(client.automaticallyDownloadsUpdates)
        XCTAssertFalse(model.automaticallyDownloadsUpdates)
    }

    func testFeedURLStringReadsTheBundleInsteadOfUserDefaults() throws {
        let suite = "PlainsongFeed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://evil.example/appcast.xml", forKey: "SUFeedURL")
        let delegate = PlainsongUpdateChannelDelegate(defaults: defaults)
        XCTAssertTrue(
            delegate.responds(to: #selector(PlainsongUpdateChannelDelegate.feedURLString(for:)))
        )
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.plainsong.editor")
        XCTAssertEqual(PlainsongUpdateChannelDelegate.feedURLString(in: .main), "")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = "https://w3d-su.github.io/plainsong/appcast.xml"
        let plist = ["SUFeedURL": feed] as NSDictionary
        try plist.write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(PlainsongUpdateChannelDelegate.feedURLString(in: bundle), feed)

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-feed-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try ([:] as NSDictionary).write(to: emptyRoot.appendingPathComponent("Info.plist"))
        let emptyBundle = try XCTUnwrap(Bundle(url: emptyRoot))
        XCTAssertEqual(PlainsongUpdateChannelDelegate.feedURLString(in: emptyBundle), "")
        XCTAssertEqual(SparkleUpdateClient.constructedCount, 0)
    }

    func testUpdateFlagParsesOnlyExplicitYes() {
        XCTAssertFalse(PlainsongUpdateConfiguration.isEnabled(infoValue: nil))
        XCTAssertFalse(PlainsongUpdateConfiguration.isEnabled(infoValue: "NO"))
        XCTAssertFalse(PlainsongUpdateConfiguration.isEnabled(infoValue: "false"))
        XCTAssertFalse(PlainsongUpdateConfiguration.isEnabled(infoValue: false))
        XCTAssertTrue(PlainsongUpdateConfiguration.isEnabled(infoValue: "YES"))
        XCTAssertTrue(PlainsongUpdateConfiguration.isEnabled(infoValue: "true"))
        XCTAssertTrue(PlainsongUpdateConfiguration.isEnabled(infoValue: true))
    }
}

@MainActor
private final class FakeUpdateClient: UpdateClient {
    private let checks: CurrentValueSubject<Bool, Never>
    private let downloads: CurrentValueSubject<Bool, Never>
    private let beta: CurrentValueSubject<Bool, Never>
    private let canCheck: CurrentValueSubject<Bool, Never>
    private(set) var checkCount = 0

    init(
        automaticallyChecksForUpdates: Bool = true,
        automaticallyDownloadsUpdates: Bool = false,
        receivesBetaUpdates: Bool = false,
        canCheckForUpdates: Bool = true
    ) {
        checks = CurrentValueSubject(automaticallyChecksForUpdates)
        downloads = CurrentValueSubject(automaticallyDownloadsUpdates)
        beta = CurrentValueSubject(receivesBetaUpdates)
        canCheck = CurrentValueSubject(canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { checks.value }
        set { checks.send(newValue) }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { downloads.value }
        set { downloads.send(newValue) }
    }

    var receivesBetaUpdates: Bool {
        get { beta.value }
        set { beta.send(newValue) }
    }

    var canCheckForUpdates: Bool {
        get { canCheck.value }
        set { canCheck.send(newValue) }
    }

    var automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never> {
        checks.eraseToAnyPublisher()
    }

    var automaticallyDownloadsUpdatesPublisher: AnyPublisher<Bool, Never> {
        downloads.eraseToAnyPublisher()
    }

    var receivesBetaUpdatesPublisher: AnyPublisher<Bool, Never> {
        beta.eraseToAnyPublisher()
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        canCheck.eraseToAnyPublisher()
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func allowedChannels() -> Set<String> {
        UpdateChannelPolicy.allowedChannels(receivesBetaUpdates: receivesBetaUpdates)
    }
}
