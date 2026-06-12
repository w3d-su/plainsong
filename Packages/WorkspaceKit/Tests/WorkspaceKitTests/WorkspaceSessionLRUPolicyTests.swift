@testable import WorkspaceKit
import XCTest

final class WorkspaceSessionLRUPolicyTests: XCTestCase {
    func testEvictsLeastRecentlyUsedCleanSessionOverLimit() {
        var policy = WorkspaceSessionLRUPolicy(limit: 2)
        let firstURL = URL(fileURLWithPath: "/tmp/a.md")
        let secondURL = URL(fileURLWithPath: "/tmp/b.md")
        let thirdURL = URL(fileURLWithPath: "/tmp/c.md")

        XCTAssertTrue(policy.access(firstURL, isDirty: false).isEmpty)
        XCTAssertTrue(policy.access(secondURL, isDirty: false).isEmpty)

        let evictions = policy.access(thirdURL, isDirty: false)

        XCTAssertEqual(evictions, [
            WorkspaceSessionEviction(url: firstURL, requiresSave: false),
        ])
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [secondURL, thirdURL])
    }

    func testAccessRefreshesRecency() {
        var policy = WorkspaceSessionLRUPolicy(limit: 2)
        let firstURL = URL(fileURLWithPath: "/tmp/a.md")
        let secondURL = URL(fileURLWithPath: "/tmp/b.md")
        let thirdURL = URL(fileURLWithPath: "/tmp/c.md")

        _ = policy.access(firstURL, isDirty: false)
        _ = policy.access(secondURL, isDirty: false)
        _ = policy.access(firstURL, isDirty: false)

        let evictions = policy.access(thirdURL, isDirty: false)

        XCTAssertEqual(evictions.map(\.url), [secondURL])
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [firstURL, thirdURL])
    }

    func testDirtySessionEvictionRequiresSaveFirst() {
        var policy = WorkspaceSessionLRUPolicy(limit: 2)
        let dirty = URL(fileURLWithPath: "/tmp/dirty.md")
        let clean = URL(fileURLWithPath: "/tmp/clean.md")
        let next = URL(fileURLWithPath: "/tmp/next.md")

        _ = policy.access(dirty, isDirty: true)
        _ = policy.access(clean, isDirty: false)

        let evictions = policy.access(next, isDirty: false)

        XCTAssertEqual(evictions, [
            WorkspaceSessionEviction(url: dirty, requiresSave: true),
        ])
    }

    func testDirtyStateCanBeUpdatedWithoutChangingRecency() {
        var policy = WorkspaceSessionLRUPolicy(limit: 2)
        let firstURL = URL(fileURLWithPath: "/tmp/a.md")
        let secondURL = URL(fileURLWithPath: "/tmp/b.md")
        let thirdURL = URL(fileURLWithPath: "/tmp/c.md")

        _ = policy.access(firstURL, isDirty: false)
        _ = policy.access(secondURL, isDirty: false)
        policy.updateDirtyState(for: firstURL, isDirty: true)

        let evictions = policy.access(thirdURL, isDirty: false)

        XCTAssertEqual(evictions, [
            WorkspaceSessionEviction(url: firstURL, requiresSave: true),
        ])
    }
}
