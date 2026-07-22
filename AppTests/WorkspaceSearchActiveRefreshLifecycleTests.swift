import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
extension WorkspaceSearchActiveRefreshTests {
    func testNamespaceMutationRefreshWaitsForInstalledSnapshotAndAuthority() async throws {
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

        let sessions: [DocumentSession] = []
        try fixture.appState.beginWorkspaceNamespaceMutation(sessions)
        fixture.appState.endWorkspaceNamespaceMutation(sessions)
        fixture.appState.drainWorkspaceMutationRefreshIfNeeded()
        await scanner.waitForRequestCount(1)
        XCTAssertEqual(provider.requests.count, 1)

        await scanner.complete(0, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("namespace refresh after install") {
            provider.requests.count == 2
        }
        XCTAssertEqual(provider.requests[1].query.pattern, "needle")
        XCTAssertEqual(
            provider.requests[1].workspaceGeneration,
            fixture.appState.workspaceInstalledCaptureGeneration
        )
    }

    func testFailedReloadDoesNotStartRetainedSearch() async throws {
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
        let installedGeneration = fixture.appState.workspaceInstalledCaptureGeneration

        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        await scanner.fail(0, with: CocoaError(.fileReadUnknown))
        try await waitForActiveSearchRefresh("reload failure handling") {
            fixture.appState.presentedError != nil
        }

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(fixture.appState.workspaceInstalledCaptureGeneration, installedGeneration)
        XCTAssertNotEqual(
            fixture.appState.workspaceInstalledCaptureGeneration,
            fixture.appState.workspaceGeneration
        )
    }

    func testRootMismatchedIntentClearsWithoutReplay() async throws {
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

        let otherRoot = try makeActiveSearchRefreshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherAuthority = try WorkspaceFileSystemRootAuthority(rootURL: otherRoot)
        fixture.appState.workspaceSearchRefreshIntent = WorkspaceSearchRefreshIntent(
            query: TextSearchQuery(pattern: "needle"),
            rootURL: fixture.rootURL,
            rootExpectation: otherAuthority.directoryMutationExpectation
        )

        await scanner.complete(0, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("root mismatch clearing") {
            fixture.appState.workspaceSearchRefreshIntent == nil
        }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(
            fixture.appState.workspaceInstalledCaptureGeneration,
            fixture.appState.workspaceGeneration
        )
    }

    func testQueryReplacementAndEmptyQueryWinDuringReload() async throws {
        let provider = ActiveSearchRefreshProvider()
        let scanner = ActiveSearchRefreshScanner()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: scanner,
            files: ["a.md": "alpha beta"]
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }

        fixture.appState.updateWorkspaceSearchQueryText("alpha")
        try await waitForActiveSearchRefresh("alpha search") { provider.requests.count == 1 }
        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        fixture.appState.updateWorkspaceSearchQueryText("beta")
        fixture.appState.setWorkspaceSearchMatchCase(true)
        fixture.appState.setWorkspaceSearchWholeWord(true)
        XCTAssertEqual(
            fixture.appState.workspaceSearchUI.pendingResumeGeneration,
            fixture.appState.workspaceGeneration
        )

        await scanner.complete(0, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("replacement search") { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].query.pattern, "beta")
        XCTAssertEqual(provider.requests[1].query.caseSensitivity, .sensitive)
        XCTAssertTrue(provider.requests[1].query.wholeWord)
        XCTAssertNil(fixture.appState.workspaceSearchUI.pendingResumeGeneration)
        XCTAssertNil(fixture.appState.workspaceSearchRefreshIntent)

        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(2)
        let emptyQueryGeneration = fixture.appState.workspaceGeneration
        fixture.appState.updateWorkspaceSearchQueryText("")
        await scanner.complete(1, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("empty-query snapshot installation") {
            fixture.appState.workspaceInstalledCaptureGeneration == emptyQueryGeneration
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertNil(fixture.appState.workspaceSearchRefreshIntent)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)
    }

    func testTeardownDuringReloadClearsIntentWithoutReplay() async throws {
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
        fixture.appState.teardownWorkspaceSearch()
        await scanner.complete(0, with: fixture.snapshot)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertNil(fixture.appState.workspaceSearchRefreshIntent)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)
    }

    func testCloseDuringReloadClearsIntentWithoutReplay() async throws {
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
        fixture.appState.closeWorkspace()
        await scanner.complete(0, with: fixture.snapshot)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertNil(fixture.appState.workspaceRootURL)
        XCTAssertNil(fixture.appState.workspaceSearchRefreshIntent)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "")
    }

    func testSwitchDuringReloadCannotReplayPreviousRootOverlay() async throws {
        let provider = ActiveSearchRefreshProvider()
        let scanner = ActiveSearchRefreshScanner()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: scanner,
            files: ["a.md": "saved A"]
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let warmA = try addActiveSearchRefreshWarmSession(
            path: "a.md",
            text: "saved A",
            to: fixture
        )

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "A"))
        try await waitForActiveSearchRefresh("root A search") { provider.requests.count == 1 }
        fixture.appState.applyDocumentText("dirty A", to: warmA)
        try await waitForActiveSearchRefresh("root A overlay refresh") { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].dirtyOverlays.overlays.map(\.text), ["dirty A"])
        fixture.appState.applyDocumentText("saved A", to: warmA)
        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)

        let rootB = try makeActiveSearchRefreshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootB) }
        try "saved B".write(
            to: rootB.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.appState.openWorkspace(url: rootB, rememberAsLastOpened: false)
        await scanner.waitForRequestCount(2)
        await scanner.complete(0, with: fixture.snapshot)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(provider.requests.count, 2)
        let snapshotB = activeSearchRefreshSnapshot(paths: ["b.md"], rootURL: rootB)
        await scanner.complete(1, with: snapshotB)
        try await waitForActiveSearchRefresh("root B installation") {
            fixture.appState.workspaceInstalledCaptureGeneration == fixture.appState.workspaceGeneration
                && fixture.appState.workspaceSearchRootAuthority != nil
        }
        XCTAssertEqual(provider.requests.count, 2)
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "B"))
        try await waitForActiveSearchRefresh("root B search") { provider.requests.count == 3 }
        XCTAssertTrue(provider.requests[2].dirtyOverlays.overlays.isEmpty)

        fixture.appState.closeWorkspace()
        XCTAssertNil(fixture.appState.workspaceSearchRefreshIntent)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "")
    }

    func testNoQueryAndIrrelevantSessionEditsCreateNoRequest() async throws {
        let provider = ActiveSearchRefreshProvider()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: ActiveSearchRefreshScanner(),
            files: ["a.md": "saved", "warm.md": "warm"],
            currentPath: "a.md",
            debounceNanoseconds: 30_000_000
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let warm = try addActiveSearchRefreshWarmSession(path: "warm.md", text: "warm", to: fixture)

        var inactiveUI = fixture.appState.workspaceSearchUI
        inactiveUI.queryText = "never-run"
        fixture.appState.workspaceSearchUI = inactiveUI
        fixture.appState.applyAuthorizedEditorText("edited without query", to: fixture.appState.currentDocument)
        fixture.appState.applyDocumentText("warm without query", to: warm)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(provider.requests.isEmpty)

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "active"))
        try await waitForActiveSearchRefresh("active search") { provider.requests.count == 1 }
        let outsideURL = try makeActiveSearchRefreshTemporaryDirectory()
            .appendingPathComponent("outside.md")
        defer { try? FileManager.default.removeItem(at: outsideURL.deletingLastPathComponent()) }
        let outsideSession = DocumentSession(text: "outside", url: outsideURL, fileKind: .markdown)
        fixture.appState.sessionCache[outsideURL] = outsideSession
        fixture.appState.applyDocumentText("outside changed", to: outsideSession)

        let nonEditableURL = fixture.rootURL.appendingPathComponent("notes.txt")
        let nonEditableSession = DocumentSession(
            text: "plain text",
            url: nonEditableURL,
            fileKind: .markdown
        )
        fixture.appState.sessionCache[nonEditableURL] = nonEditableSession
        fixture.appState.applyDocumentText("plain text changed", to: nonEditableSession)

        if let warmURL = warm.fileURL {
            fixture.appState.detachedSessionURLs.insert(warmURL)
        }
        fixture.appState.applyDocumentText("detached changed", to: warm)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testModeQueryOptionsAndFocusReceiptsSurviveAutomaticRefresh() async throws {
        let provider = ActiveSearchRefreshProvider()
        let scanner = ActiveSearchRefreshScanner()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: scanner,
            files: ["a.md": "saved needle"],
            debounceNanoseconds: 30_000_000
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let warm = try addActiveSearchRefreshWarmSession(
            path: "a.md",
            text: "saved needle",
            to: fixture
        )

        fixture.appState.workspaceSearchUI = WorkspaceSearchUIState(
            mode: .search,
            queryText: "needle",
            matchCase: true,
            wholeWord: true,
            focusRequestID: 9,
            focusAppliedID: 9
        )
        fixture.appState.publishWorkspaceSearchQueryFromUI()
        try await waitForActiveSearchRefresh("initial configured search") {
            provider.requests.count == 1
        }
        let uiBeforeRefresh = fixture.appState.workspaceSearchUI
        let generationBeforeRefresh = fixture.appState.workspaceSearchState.queryGeneration

        fixture.appState.applyDocumentText("latest needle", to: warm)
        try await waitForActiveSearchRefresh("automatic edit refresh") {
            provider.requests.count == 2
        }

        XCTAssertEqual(fixture.appState.workspaceSearchUI, uiBeforeRefresh)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "needle")
        XCTAssertTrue(fixture.appState.workspaceSearchUI.matchCase)
        XCTAssertTrue(fixture.appState.workspaceSearchUI.wholeWord)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.focusRequestID, 9)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.focusAppliedID, 9)
        XCTAssertGreaterThan(
            fixture.appState.workspaceSearchState.queryGeneration,
            generationBeforeRefresh
        )
        XCTAssertEqual(provider.requests[1].query.caseSensitivity, .sensitive)
        XCTAssertTrue(provider.requests[1].query.wholeWord)

        fixture.appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        await scanner.complete(0, with: fixture.snapshot)
        try await waitForActiveSearchRefresh("automatic reload refresh") {
            provider.requests.count == 3
        }
        XCTAssertEqual(fixture.appState.workspaceSearchUI, uiBeforeRefresh)
        XCTAssertEqual(provider.requests[2].query.caseSensitivity, .sensitive)
        XCTAssertTrue(provider.requests[2].query.wholeWord)
    }
}
