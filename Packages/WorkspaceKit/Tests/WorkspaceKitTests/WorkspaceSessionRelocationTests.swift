@testable import WorkspaceKit
import XCTest

final class WorkspaceSessionRelocationTests: XCTestCase {
    func testRelocatePreservesExactDestinationURLDirtyStateAndRecency() throws {
        let oldURL = try XCTUnwrap(URL(string: "file:///tmp/cafe%CC%81-old.md"))
        let newURL = try XCTUnwrap(URL(string: "file:///tmp/caf%C3%A9-new.md"))
        let mostRecentURL = URL(fileURLWithPath: "/tmp/most-recent.md")
        var policy = WorkspaceSessionLRUPolicy(limit: 3)
        _ = policy.access(oldURL, isDirty: true)
        _ = policy.access(mostRecentURL, isDirty: false)

        try policy.relocate(from: oldURL, to: newURL)

        XCTAssertNil(policy.dirtyState(for: oldURL))
        XCTAssertEqual(policy.dirtyState(for: newURL), true)
        XCTAssertEqual(
            policy.warmURLsInLeastRecentOrder.map(\.absoluteString),
            [newURL.absoluteString, mostRecentURL.absoluteString]
        )
    }

    func testRelocateThrowsOnDestinationCollisionWithoutMutatingEitherEntry() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.md")
        let destinationURL = URL(fileURLWithPath: "/tmp/destination.md")
        var policy = WorkspaceSessionLRUPolicy(limit: 3)
        _ = policy.access(sourceURL, isDirty: true)
        _ = policy.access(destinationURL, isDirty: false)
        let policyBeforeRelocation = policy

        XCTAssertThrowsError(try policy.relocate(from: sourceURL, to: destinationURL))

        XCTAssertEqual(policy, policyBeforeRelocation)
        XCTAssertEqual(policy.dirtyState(for: sourceURL), true)
        XCTAssertEqual(policy.dirtyState(for: destinationURL), false)
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [sourceURL, destinationURL])
    }
}
