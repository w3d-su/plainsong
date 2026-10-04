import Foundation
import XCTest

final class CIFailureArtifactUploadProbeTests: XCTestCase {
    func testIntentionalHostedFailureRetainsArtifacts() throws {
        guard ProcessInfo.processInfo.environment["CI"] == "true" else {
            throw XCTSkip("One-time hosted CI artifact verification only.")
        }
        XCTFail(
            "Intentional handoff 23 artifact-upload probe; revert this commit after verifying the failure artifact."
        )
    }
}
