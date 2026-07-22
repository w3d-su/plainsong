// swiftlint:disable type_body_length
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WorkspaceSearchActiveRefreshTests: XCTestCase {
    func testCurrentAndWarmSessionEditsRefreshWithLatestOverlays() async throws {
        let provider = ActiveSearchRefreshProvider()
        let scanner = ActiveSearchRefreshScanner()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: scanner,
            files: ["current.md": "saved current", "warm.mdx": "saved warm"],
            currentPath: "current.md",
            debounceNanoseconds: 40_000_000
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let warm = try addActiveSearchRefreshWarmSession(
            path: "warm.mdx",
            text: "saved warm",
            to: fixture
        )

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "latest"))
        try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }

        fixture.appState.applyAuthorizedEditorText("current draft", to: fixture.appState.currentDocument)
        fixture.appState.applyAuthorizedEditorText("current latest", to: fixture.appState.currentDocument)
        fixture.appState.applyDocumentText("warm draft", to: warm)
        fixture.appState.applyDocumentText("warm latest", to: warm)

        try await waitForActiveSearchRefresh("coalesced overlay refresh") {
            provider.requests.count == 2
        }
        let overlays = Dictionary(uniqueKeysWithValues: provider.requests[1].dirtyOverlays.overlays.map {
            ($0.relativePath, $0.text)
        })
        XCTAssertEqual(overlays, [
            "current.md": "current latest",
            "warm.mdx": "warm latest",
        ])
        XCTAssertEqual(provider.requests[1].query.pattern, "latest")
    }

    func testRapidEditsCoalesceAndCancelledProducerLateEventsCannotWin() async throws {
        let provider = ActiveSearchRefreshProvider()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: ActiveSearchRefreshScanner(),
            files: ["a.md": "saved"],
            currentPath: "a.md",
            debounceNanoseconds: 50_000_000
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitForActiveSearchRefresh("initial producer") { provider.requests.count == 1 }
        let oldRequest = provider.requests[0]

        fixture.appState.applyAuthorizedEditorText("needle one", to: fixture.appState.currentDocument)
        fixture.appState.applyAuthorizedEditorText("needle two", to: fixture.appState.currentDocument)
        fixture.appState.applyAuthorizedEditorText("needle newest", to: fixture.appState.currentDocument)

        try await waitForActiveSearchRefresh("old producer cancellation and one refresh") {
            provider.terminatedIndices.contains(0) && provider.requests.count == 2
        }
        provider.yield(
            .fileResult(
                activeSearchRefreshContext(oldRequest),
                activeSearchRefreshResult(path: "a.md", text: "needle stale", needle: "needle")
            ),
            to: 0
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(fixture.appState.workspaceSearchState.fileResults.isEmpty)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(
            provider.requests[1].dirtyOverlays.overlays.first?.text,
            "needle newest"
        )
    }

    func testUndoToSavedBaselineOmitsDirtyOverlay() async throws {
        let provider = ActiveSearchRefreshProvider()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: ActiveSearchRefreshScanner(),
            files: ["a.md": "saved baseline"],
            currentPath: "a.md",
            debounceNanoseconds: 40_000_000
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "saved"))
        try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }
        fixture.appState.applyAuthorizedEditorText("dirty saved", to: fixture.appState.currentDocument)
        fixture.appState.applyAuthorizedEditorText("saved baseline", to: fixture.appState.currentDocument)

        try await waitForActiveSearchRefresh("baseline refresh") { provider.requests.count == 2 }
        XCTAssertFalse(fixture.appState.currentDocument.isDirty)
        XCTAssertTrue(provider.requests[1].dirtyOverlays.overlays.isEmpty)
    }

    func testCompletedAndInFlightSearchesRestartOnlyAfterReloadInstallation() async throws {
        for shouldCompleteSearch in [false, true] {
            let provider = ActiveSearchRefreshProvider()
            let scanner = ActiveSearchRefreshScanner()
            let fixture = try makeActiveSearchRefreshFixture(
                provider: provider,
                scanner: scanner,
                files: ["a.md": "needle"]
            )
            defer { cleanUpActiveSearchRefreshFixture(fixture) }

            fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
            try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }
            if shouldCompleteSearch {
                let request = provider.requests[0]
                provider.yield(
                    .completed(
                        activeSearchRefreshContext(request),
                        WorkspaceSearchSummary(
                            candidateFileCount: 1,
                            searchedFileCount: 1,
                            skippedFileCount: 0,
                            ignoredFileCount: 0,
                            totalEmittedMatchCount: 1,
                            truncatedFilePaths: [],
                            isGloballyTruncated: false,
                            skippedFiles: [],
                            omittedSkippedFileCount: 0,
                            readInstrumentation: .init(
                                diskReadCount: 1,
                                diskReadByteCount: 6,
                                maximumConcurrentReads: 1,
                                maximumBufferedReadCount: 0,
                                maximumOutstandingReadCount: 1
                            )
                        )
                    ),
                    to: 0
                )
                provider.finish(0)
                try await waitForActiveSearchRefresh("completed state") {
                    fixture.appState.workspaceSearchState.phase == .completed
                }
            }

            fixture.appState.refreshWorkspaceAfterFileSystemChange()
            await scanner.waitForRequestCount(1)
            XCTAssertEqual(provider.requests.count, 1)
            XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)

            await scanner.complete(0, with: fixture.snapshot)
            try await waitForActiveSearchRefresh("post-install search") {
                provider.requests.count == 2
            }
            XCTAssertEqual(provider.requests[1].workspaceGeneration, fixture.appState.workspaceGeneration)
            XCTAssertEqual(provider.requests[1].query.pattern, "needle")
        }
    }

    func testOverlappingReloadsRefreshOnlyNewestSuccessfulGeneration() async throws {
        let provider = ActiveSearchRefreshProvider()
        let scanner = ActiveSearchRefreshScanner()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: scanner,
            files: ["a.md": "needle"]
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }
        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(2)

        await scanner.complete(0, with: fixture.snapshot)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 1)

        await scanner.complete(1, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("newest generation refresh") {
            provider.requests.count == 2
        }
        XCTAssertEqual(provider.requests[1].workspaceGeneration, fixture.appState.workspaceGeneration)
        XCTAssertEqual(
            fixture.appState.workspaceInstalledCaptureGeneration,
            fixture.appState.workspaceGeneration
        )
    }
}
