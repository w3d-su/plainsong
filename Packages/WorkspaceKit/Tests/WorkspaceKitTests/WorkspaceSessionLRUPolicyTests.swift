@testable import WorkspaceKit
import XCTest

final class WorkspaceSessionLRUPolicyTests: XCTestCase {
    func testEvictionRetainsDistinctNFCAndNFDURLSpellings() throws {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let nfc = try XCTUnwrap(URL(string: "file:///tmp/caf%C3%A9.md"))
        let nfd = try XCTUnwrap(URL(string: "file:///tmp/cafe%CC%81.md"))

        XCTAssertTrue(policy.access(nfc, isDirty: false).isEmpty)
        let evictions = policy.access(nfd, isDirty: false)

        XCTAssertEqual(evictions, [WorkspaceSessionEviction(url: nfc, requiresSave: false)])
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [nfd])
        XCTAssertNil(policy.dirtyState(for: nfc))
        XCTAssertEqual(policy.dirtyState(for: nfd), false)
    }

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

    func testProtectedInstalledSessionStaysTrackedUntilHandoffThenEvictsWithLatestDirtyState() {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let installedURL = URL(fileURLWithPath: "/tmp/installed.md")
        let candidateURL = URL(fileURLWithPath: "/tmp/candidate.md")

        _ = policy.access(installedURL, isDirty: false)
        let prematureEvictions = policy.access(
            candidateURL,
            isDirty: false,
            protectedURLs: [installedURL, candidateURL]
        )
        policy.updateDirtyState(for: installedURL, isDirty: true)

        XCTAssertTrue(prematureEvictions.isEmpty)
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [installedURL, candidateURL])
        XCTAssertEqual(policy.dirtyState(for: installedURL), true)
        XCTAssertEqual(
            policy.trim(protectedURLs: [candidateURL]),
            [WorkspaceSessionEviction(url: installedURL, requiresSave: true)]
        )
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [candidateURL])
    }

    func testInstalledSessionsDoNotCountTowardWarmCapacity() {
        var policy = WorkspaceSessionLRUPolicy(limit: 8)
        let installed = (0 ..< 3).map { URL(fileURLWithPath: "/tmp/installed-\($0).md") }
        let installedURLs = Set(installed)
        for url in installed {
            XCTAssertTrue(policy.access(url, isDirty: false, installedURLs: installedURLs).isEmpty)
        }
        let warm = (0 ..< 8).map { URL(fileURLWithPath: "/tmp/warm-\($0).md") }
        for url in warm {
            XCTAssertTrue(policy.access(url, isDirty: false, installedURLs: installedURLs).isEmpty)
        }

        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, installed + warm)

        let extra = URL(fileURLWithPath: "/tmp/extra.md")
        let evictions = policy.access(extra, isDirty: false, installedURLs: installedURLs)

        XCTAssertEqual(evictions.map(\.url), [warm[0]])
        XCTAssertEqual(
            policy.warmURLsInLeastRecentOrder,
            installed + Array(warm.dropFirst()) + [extra]
        )
    }

    func testProtectedSessionsStillCountBesideInstalledSessions() {
        var policy = WorkspaceSessionLRUPolicy(limit: 2)
        let installed = URL(fileURLWithPath: "/tmp/installed.md")
        let protected = URL(fileURLWithPath: "/tmp/protected.md")
        let warm = URL(fileURLWithPath: "/tmp/warm.md")
        let incoming = URL(fileURLWithPath: "/tmp/incoming.md")
        let installedURLs: Set<URL> = [installed]
        let protectedURLs: Set<URL> = [protected]

        XCTAssertTrue(policy.access(
            installed,
            isDirty: false,
            protectedURLs: protectedURLs,
            installedURLs: installedURLs
        ).isEmpty)
        XCTAssertTrue(policy.access(
            protected,
            isDirty: false,
            protectedURLs: protectedURLs,
            installedURLs: installedURLs
        ).isEmpty)
        XCTAssertTrue(policy.access(
            warm,
            isDirty: false,
            protectedURLs: protectedURLs,
            installedURLs: installedURLs
        ).isEmpty)

        let evictions = policy.access(
            incoming,
            isDirty: false,
            protectedURLs: protectedURLs,
            installedURLs: installedURLs
        )

        XCTAssertEqual(evictions.map(\.url), [warm])
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [installed, protected, incoming])
    }

    func testProtectedURLsOutsideTheCacheDoNotFreeWarmCapacity() {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let warm = URL(fileURLWithPath: "/tmp/warm.md")
        let incoming = URL(fileURLWithPath: "/tmp/incoming.md")
        let absent = URL(fileURLWithPath: "/tmp/absent.md")

        XCTAssertTrue(policy.access(warm, isDirty: false).isEmpty)
        XCTAssertEqual(
            policy.access(incoming, isDirty: false, protectedURLs: [absent]).map(\.url),
            [warm]
        )
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [incoming])
    }

    func testFailedOrFencedProtectionRetainsTheOverLimitCache() {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let fenced = URL(fileURLWithPath: "/tmp/fenced.md")
        let retained = URL(fileURLWithPath: "/tmp/retained.md")
        let protectedURLs: Set<URL> = [fenced, retained]

        XCTAssertTrue(policy.access(fenced, isDirty: true, protectedURLs: [fenced]).isEmpty)
        XCTAssertTrue(policy.access(
            retained,
            isDirty: true,
            protectedURLs: protectedURLs
        ).isEmpty)
        XCTAssertTrue(policy.trim(protectedURLs: protectedURLs).isEmpty)
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [fenced, retained])
        XCTAssertEqual(policy.dirtyState(for: fenced), true)
        XCTAssertEqual(policy.dirtyState(for: retained), true)
    }

    func testInstalledAndProtectedURLDoesNotCountTowardWarmCapacity() {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let both = URL(fileURLWithPath: "/tmp/both.md")
        let warm = URL(fileURLWithPath: "/tmp/warm.md")
        let incoming = URL(fileURLWithPath: "/tmp/incoming.md")

        XCTAssertTrue(policy.access(
            both,
            isDirty: false,
            protectedURLs: [both],
            installedURLs: [both]
        ).isEmpty)
        XCTAssertTrue(policy.access(
            warm,
            isDirty: false,
            protectedURLs: [both],
            installedURLs: [both]
        ).isEmpty)

        XCTAssertEqual(
            policy.access(
                incoming,
                isDirty: false,
                protectedURLs: [both],
                installedURLs: [both]
            ).map(\.url),
            [warm]
        )
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [both, incoming])
    }

    func testTrimKeepsInstalledSessionsOutsideWarmCapacity() {
        var policy = WorkspaceSessionLRUPolicy(limit: 1)
        let installed = URL(fileURLWithPath: "/tmp/installed.md")
        let warm = URL(fileURLWithPath: "/tmp/warm.md")

        XCTAssertTrue(policy.access(installed, isDirty: false, installedURLs: [installed]).isEmpty)
        XCTAssertTrue(policy.access(warm, isDirty: true, installedURLs: [installed]).isEmpty)
        XCTAssertTrue(policy.trim(installedURLs: [installed]).isEmpty)
        XCTAssertEqual(
            policy.trim(),
            [WorkspaceSessionEviction(url: installed, requiresSave: false)]
        )
        XCTAssertEqual(policy.warmURLsInLeastRecentOrder, [warm])
        XCTAssertEqual(policy.dirtyState(for: warm), true)
    }
}
