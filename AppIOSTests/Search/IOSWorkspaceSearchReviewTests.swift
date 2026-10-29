import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceSearchReviewTests: XCTestCase {
    func testProbeStopsAndReportsAChangedGrant() async {
        for failure in [IOSWorkspaceFailure.grantChanged, .outsideGrant] {
            let controller = IOSWorkspaceSearchController(maximumMatchesPerFile: 5, maximumMatchesPerQuery: 1)
            var reads: [String] = []
            let environment = IOSWorkspaceSearchEnvironment(
                scope: .directory,
                entries: ["a.md", "b.md", "c.md"].map { ShellFixtures.entry($0) },
                openDocument: nil,
                read: { location in
                    reads.append(location.relativePath)
                    if location.relativePath == "b.md" {
                        throw failure
                    }
                    return "hit"
                }
            )

            await controller.searchNow(query: "hit", environment: environment)

            XCTAssertEqual(reads, ["a.md", "b.md"])
            XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md"])
            XCTAssertEqual(controller.statusText, "The folder changed. Search again.")
            XCTAssertFalse(controller.isSearching)
        }
    }

    func testInvalidationDuringSizeRefusalDoesNotCacheTheOldResult() async {
        await assertInvalidatedRefusalIsNotCached(.tooLarge)
    }

    func testInvalidationDuringEncodingRefusalDoesNotCacheTheOldResult() async {
        await assertInvalidatedRefusalIsNotCached(.unsupportedEncoding)
    }

    func testUnchangedRefusalsAreStillCached() async {
        for refusal in [IOSWorkspaceSearchReadError.tooLarge, .unsupportedEncoding] {
            let controller = IOSWorkspaceSearchController()
            var reads = 0
            let environment = IOSWorkspaceSearchEnvironment(
                scope: .directory,
                entries: [ShellFixtures.entry("a.md")],
                openDocument: nil,
                read: { _ in
                    reads += 1
                    throw refusal
                }
            )

            await controller.searchNow(query: "hit", environment: environment)
            XCTAssertEqual(controller.cachedReadCountForTesting, 1)
            controller.scheduleSearch(environment: environment, immediate: true, reusingReads: true)
            await waitForIdle(controller)

            XCTAssertEqual(reads, 1)
            XCTAssertTrue(controller.sections.isEmpty)
        }
    }

    private func assertInvalidatedRefusalIsNotCached(
        _ refusal: IOSWorkspaceSearchReadError
    ) async {
        let controller = IOSWorkspaceSearchController()
        let entry = ShellFixtures.entry("a.md")
        var reads = 0
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [entry],
            openDocument: nil,
            read: { location in
                reads += 1
                if reads == 1 {
                    // A provider notice arrives after the read captured its cache epoch,
                    // but before that read delivers its now-obsolete refusal.
                    controller.invalidateCachedRead(location)
                    throw refusal
                }
                return "fresh hit"
            }
        )

        await controller.searchNow(query: "hit", environment: environment)
        XCTAssertEqual(controller.cachedReadCountForTesting, 0)
        controller.scheduleSearch(environment: environment, immediate: true, reusingReads: true)
        await waitForIdle(controller)

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(controller.sections.first?.hits.map(\.matchedText), ["hit"])
        XCTAssertFalse(controller.statusText.contains("too large"))
        XCTAssertFalse(controller.statusText.contains("not plain UTF-8"))
    }

    private func waitForIdle(_ controller: IOSWorkspaceSearchController) async {
        for _ in 0 ..< 200 where controller.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isSearching)
    }
}
