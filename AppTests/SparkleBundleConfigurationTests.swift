import Foundation
@testable import Plainsong
import Security
import XCTest

/// U-G2: the built app's Sparkle keys and entitlements match the sandboxing
/// plan, and the default build never starts an updater.
@MainActor
final class SparkleBundleConfigurationTests: XCTestCase {
    func testBuiltAppDisablesUpdatesAndMatchesSandboxKeys() throws {
        let bundle = try plainsongAppBundle()
        let info = try XCTUnwrap(bundle.infoDictionary)
        let sparkleKeys = Set(info.keys.filter { $0.hasPrefix("SU") })
        XCTAssertEqual(
            sparkleKeys,
            [
                "SUEnableInstallerLauncherService",
                "SUFeedURL",
                "SUPublicEDKey",
            ]
        )
        XCTAssertEqual(plistBool(info["SUEnableInstallerLauncherService"]), true)
        XCTAssertEqual(info["SUFeedURL"] as? String, "")
        XCTAssertEqual(info["SUPublicEDKey"] as? String, "")
        XCTAssertNil(info["SUEnableDownloaderService"])
        XCTAssertNil(info["SUEnableSystemProfiling"])
        let updatesFlag = info[PlainsongUpdateConfiguration.enabledKey]
        XCTAssertNotEqual(updatesFlag as? String, "$(PLAINSONG_UPDATES_ENABLED)")
        XCTAssertFalse(PlainsongUpdateConfiguration.isEnabled(in: bundle))

        let startsBefore = SparkleUpdateClient.startCount
        let center = AppUpdateCenter.make(bundle: bundle)
        XCTAssertFalse(center.isEnabled)
        XCTAssertNil(center.settingsModel)
        XCTAssertNil(center.checkForUpdatesModel)
        XCTAssertEqual(SparkleUpdateClient.startCount, startsBefore)
        XCTAssertEqual(startsBefore, 0, "launching the default app must not start Sparkle")

        let entitlements = try entitlementDictionary(bundleURL: bundle.bundleURL)
        let machKey = "com.apple.security.temporary-exception.mach-lookup.global-name"
        let machNames = stringList(entitlements[machKey])
        // xcodebuild test injects testmanagerd lookups into the host signature.
        // The Sparkle names are the ones §3.2 adds; -spkd would mean the downloader service.
        let sparkleNames = machNames.filter {
            $0.hasSuffix("-spks") || $0.hasSuffix("-spki") || $0.hasSuffix("-spkd")
        }
        XCTAssertEqual(
            sparkleNames.sorted(),
            ["app.plainsong.editor-spki", "app.plainsong.editor-spks"]
        )
        for key in [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.network.client",
            "com.apple.security.print",
        ] {
            XCTAssertEqual(plistBool(entitlements[key]), true, key)
        }
    }
}

private func plainsongAppBundle() throws -> Bundle {
    let candidates = [Bundle.main, Bundle(for: PlainsongApplicationDelegate.self)]
    if let bundle = candidates.first(where: { $0.bundleIdentifier == "app.plainsong.editor" }) {
        return bundle
    }
    throw CocoaError(
        .fileNoSuchFile,
        userInfo: [NSFilePathErrorKey: candidates.map(\.bundleURL.path).joined(separator: ", ")]
    )
}

private func entitlementDictionary(bundleURL: URL) throws -> [String: Any] {
    var staticCode: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
    guard created == errSecSuccess, let staticCode else {
        throw CocoaError(.fileReadCorruptFile, userInfo: ["status": created])
    }
    var information: CFDictionary?
    let copied = SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
    )
    guard copied == errSecSuccess, let information else {
        throw CocoaError(.fileReadCorruptFile, userInfo: ["status": copied])
    }
    let dictionary = information as NSDictionary
    guard let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return entitlements
}

private func plistBool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
        value
    case let value as NSNumber:
        value.boolValue
    default:
        nil
    }
}

private func stringList(_ value: Any?) -> [String] {
    if let values = value as? [String] {
        return values
    }
    if let values = value as? [Any] {
        return values.compactMap { $0 as? String }
    }
    return []
}
