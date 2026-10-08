import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceContractTests: XCTestCase {
    func testDescriptorsRetainUnicodeSpellingAndOpaqueResourceBytes() {
        let paths = ["caf\u{00e9}.md", "cafe\u{0301}.md"]
        let workspace = IOSWorkspaceIdentity(rawValue: UUID())
        let locations = paths.map { path in
            IOSFileLocation(
                workspaceID: workspace, accessGeneration: 3, relativePath: path,
                fileURL: URL(fileURLWithPath: "/synthetic/" + path),
                resourceID: IOSWorkspaceResourceIdentity(rawValue: Data(path.utf8))
            )
        }
        XCTAssertNotEqual(Array(locations[0].relativePath.utf8), Array(locations[1].relativePath.utf8))
        XCTAssertNotEqual(locations[0].resourceID, locations[1].resourceID)
        XCTAssertEqual(locations[1].resourceID?.rawValue, Data(paths[1].utf8))
    }
}
