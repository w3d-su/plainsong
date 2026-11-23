import Foundation
import XCTest

/// The app links PreviewKit, which reads `ProcessInfo.systemUptime` for render timing.
/// App Store Connect rejects a build (ITMS-91053) whose manifest omits that category.
final class IOSPrivacyManifestTests: XCTestCase {
    func testManifestDeclaresEveryRequiredReasonAPIInUse() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try XCTUnwrap(plist as? [String: Any])
        let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for type in types {
            let name = try XCTUnwrap(type["NSPrivacyAccessedAPIType"] as? String)
            reasons[name] = type["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        // `fstat` on files the user picked (preview asset readers).
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["3B52.1"])
    }
}
