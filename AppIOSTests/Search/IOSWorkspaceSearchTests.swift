import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceSearchTests: XCTestCase {
    func testSearchUsesTheOpenBufferAndReportsSkippedFiles() async {
        let open = ShellFixtures.entry("posts/a.md")
        let other = ShellFixtures.entry("posts/b.md")
        let pending = ShellFixtures.entry("posts/c.md", availability: .downloading)
        let folder = ShellFixtures.entry(
            "posts",
            kind: .directory,
            children: [pending, other, open]
        )
        var reads: [String] = []
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [folder, ShellFixtures.entry("pic.png", kind: .image)],
            openDocument: IOSWorkspaceSearchOpenDocument(
                workspaceID: ShellFixtures.workspaceID,
                relativePath: "posts/a.md",
                text: "live match stays"
            ),
            read: { location async throws -> String in
                reads.append(location.relativePath)
                switch location.relativePath {
                case "posts/b.md":
                    return "no hit here"
                case "posts/big.md":
                    throw IOSWorkspaceSearchReadError.tooLarge
                default:
                    return "disk match"
                }
            }
        )
        let controller = IOSWorkspaceSearchController()
        await controller.searchNow(query: "match", environment: environment)

        XCTAssertEqual(reads, ["posts/b.md"])
        XCTAssertEqual(controller.sections.map(\.relativePath), ["posts/a.md"])
        XCTAssertEqual(controller.sections.first?.hits.map(\.matchedText), ["match"])
        XCTAssertTrue(controller.statusText.contains("1 match in 1 file"))
        XCTAssertTrue(controller.statusText.contains("1 file is unavailable"))
        XCTAssertFalse(controller.isSearching)
    }

    func testSearchRejectsASingleFileGrantAndInvalidPatternsWithoutReading() async {
        var reads = 0
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .singleFile,
            entries: [ShellFixtures.entry("note.md")],
            openDocument: nil,
            read: { _ async throws -> String in
                reads += 1
                return "match"
            }
        )
        let controller = IOSWorkspaceSearchController()
        await controller.searchNow(query: "match", environment: environment)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.statusText, "Open a folder to search across files.")

        let directory = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("note.md")],
            openDocument: nil,
            read: { _ async throws -> String in
                reads += 1
                return "match"
            }
        )
        await controller.searchNow(query: "line\nbreak", environment: directory)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.statusText, "The search text cannot contain a line break.")
    }

    func testSearchStopsAtTheQueryLimitAndKeepsWholeWords() async {
        let first = ShellFixtures.entry("a.md")
        let second = ShellFixtures.entry("b.md")
        let controller = IOSWorkspaceSearchController(maximumMatchesPerFile: 5, maximumMatchesPerQuery: 1)
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [second, first],
            openDocument: nil,
            read: { location async throws -> String in
                location.relativePath == "a.md" ? "hit and hit" : "hit"
            }
        )
        await controller.searchNow(query: "hit", environment: environment)
        XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md"])
        XCTAssertEqual(controller.sections.first?.hits.count, 1)
        XCTAssertTrue(controller.statusText.contains("Showing the first 1 matches"))

        let words = IOSWorkspaceSearchController()
        let wordEnvironment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("words.md")],
            openDocument: nil,
            read: { _ async throws -> String in "catch cat" }
        )
        await words.searchNow(query: "cat", environment: wordEnvironment, wholeWord: true)
        XCTAssertEqual(words.sections.first?.hits.map(\.matchedText), ["cat"])
    }

    func testSearchCountsLargeAndForeignFiles() async {
        let controller = IOSWorkspaceSearchController()
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("big.md"), ShellFixtures.entry("odd.md"), ShellFixtures.entry("ok.md")],
            openDocument: nil,
            read: { location async throws -> String in
                switch location.relativePath {
                case "big.md": throw IOSWorkspaceSearchReadError.tooLarge
                case "odd.md": throw IOSWorkspaceSearchReadError.unsupportedEncoding
                default: return "found"
                }
            }
        )
        await controller.searchNow(query: "found", environment: environment)
        XCTAssertEqual(controller.sections.map(\.relativePath), ["ok.md"])
        XCTAssertTrue(controller.statusText.contains("1 file is too large"))
        XCTAssertTrue(controller.statusText.contains("1 file is not plain UTF-8"))
    }

    func testActivatingAMatchRevealsTheOpenDocumentWithoutReopeningIt() async throws {
        let stored = ShellFixtures.storedDocument(text: "before match after", path: "posts/a.md")
        let editor = FakeEditorBinding(text: "before match after", identity: stored.revision.documentID)
        let entry = ShellFixtures.entry("posts/a.md")
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: stored,
                workspace: ShellFixtures.workspace(entries: [entry])
            ),
            capabilities: IOSSceneCapabilities(
                editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(
            facade: facade,
            surfaces: IOSShellFeatureSurfaces(currentGrant: { ShellFixtures.grant() })
        )
        scene.startObserving()
        defer { scene.stopObserving() }
        scene.presentWorkspaceSearch()
        await scene.workspaceSearch.searchNow(query: "match", environment: scene.workspaceSearchEnvironment())

        let section = try XCTUnwrap(scene.workspaceSearch.sections.first)
        let hit = try XCTUnwrap(section.hits.first)
        scene.openWorkspaceSearchHit(hit, in: section)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(facade.openedURLs.isEmpty)
        XCTAssertEqual(editor.revealCalls.map(\.range), [hit.range])
        XCTAssertNil(scene.presentation)
        XCTAssertEqual(scene.navigationPath, [.document])
    }

    func testActivatingAnotherFileOpensItAndSelectsTheMatch() async throws {
        let current = ShellFixtures.storedDocument(text: "current", path: "posts/a.md")
        let editor = FakeEditorBinding(text: "current", identity: current.revision.documentID)
        let target = ShellFixtures.entry("posts/b.md")
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(
                document: current,
                workspace: ShellFixtures.workspace(entries: [ShellFixtures.entry("posts/a.md"), target])
            ),
            capabilities: IOSSceneCapabilities(
                editor: editor, documents: nil, workspace: nil, preview: nil, assets: nil
            )
        )
        facade.onOpen = { url, _ in
            XCTAssertEqual(url.lastPathComponent, "b.md")
            editor.session.replaceTextFromAuthorizedEditor("see match now")
            let opened = ShellFixtures.storedDocument(text: "see match now", path: "posts/b.md")
            // The fake editor identity has to match the document the shell verifies.
            let aligned = IOSStoredDocumentSnapshot(
                revision: IOSDocumentRevision(documentID: editor.identity, version: editor.revision),
                document: editor.session.snapshot,
                location: target.location,
                state: opened.state
            )
            facade.emit(ShellFixtures.sceneSnapshot(
                document: aligned,
                workspace: facade.snapshot.workspace
            ))
        }
        let scene = IOSShellSceneState(
            facade: facade,
            surfaces: IOSShellFeatureSurfaces(
                currentGrant: { ShellFixtures.grant() },
                readWorkspaceDocument: { location in
                    location.relativePath == "posts/b.md" ? "see match now" : "current"
                }
            )
        )
        scene.startObserving()
        defer { scene.stopObserving() }
        await scene.workspaceSearch.searchNow(query: "match", environment: scene.workspaceSearchEnvironment())
        let section = try XCTUnwrap(scene.workspaceSearch.sections.first { $0.relativePath == "posts/b.md" })
        let hit = try XCTUnwrap(section.hits.first)
        scene.present(.workspaceSearch)
        scene.openWorkspaceSearchHit(hit, in: section)
        // A second tap before the first activation finishes does not open the file again.
        scene.openWorkspaceSearchHit(hit, in: section)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(facade.openedURLs.map(\.url.lastPathComponent), ["b.md"])
        XCTAssertEqual(editor.revealCalls.map(\.range), [hit.range])
        XCTAssertNil(scene.presentation)
    }

    func testTruncationIsReportedOnlyWhenAnotherMatchExists() async {
        let controller = IOSWorkspaceSearchController(maximumMatchesPerFile: 5, maximumMatchesPerQuery: 2)
        var later = "nothing here"
        let environment = { IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("a.md"), ShellFixtures.entry("b.md")],
            openDocument: nil,
            read: { location async throws -> String in
                location.relativePath == "a.md" ? "hit hit" : later
            }
        ) }
        await controller.searchNow(query: "hit", environment: environment())
        XCTAssertEqual(controller.sections.first?.hits.count, 2)
        XCTAssertFalse(controller.statusText.contains("Showing the first"), controller.statusText)

        later = "one more hit"
        await controller.searchNow(query: "hit", environment: environment())
        XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md"])
        XCTAssertTrue(controller.statusText.contains("Showing the first 2 matches"), controller.statusText)
    }

    func testBufferEditsReuseEarlierReadsAndTreeChangesReadAgain() async {
        var reads: [String] = []
        var bText = "disk hit"
        let open = ShellFixtures.entry("a.md")
        let other = ShellFixtures.entry("b.md")
        func environment(buffer: String) -> IOSWorkspaceSearchEnvironment {
            IOSWorkspaceSearchEnvironment(
                scope: .directory,
                entries: [open, other],
                openDocument: IOSWorkspaceSearchOpenDocument(
                    workspaceID: ShellFixtures.workspaceID,
                    relativePath: "a.md",
                    text: buffer
                ),
                read: { location async throws -> String in
                    reads.append(location.relativePath)
                    return bText
                }
            )
        }
        let controller = IOSWorkspaceSearchController()
        await controller.searchNow(query: "hit", environment: environment(buffer: "no"))
        XCTAssertEqual(reads, ["b.md"])
        XCTAssertEqual(controller.cachedReadCountForTesting, 1)

        // An edit to the open buffer re-searches it without reading b.md again.
        controller.scheduleSearch(environment: environment(buffer: "hit"), immediate: true, reusingReads: true)
        await waitForIdle(controller)
        XCTAssertEqual(reads, ["b.md"])
        XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md", "b.md"])

        // A tree change (or a new search) reads from disk again.
        bText = "changed"
        controller.scheduleSearch(environment: environment(buffer: "hit"), immediate: true)
        await waitForIdle(controller)
        XCTAssertEqual(reads, ["b.md", "b.md"])
        XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md"])
    }

    func testSearchStopsReadingAfterTheMatchCap() async {
        let controller = IOSWorkspaceSearchController(maximumMatchesPerFile: 5, maximumMatchesPerQuery: 1)
        var reads: [String] = []
        let extras = (0 ..< 30).map { ShellFixtures.entry(String(format: "p%02d.md", $0)) }
        let environment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("a.md")] + extras,
            openDocument: nil,
            read: { location async throws -> String in
                reads.append(location.relativePath)
                return location.relativePath == "a.md" ? "hit" : "none"
            }
        )
        await controller.searchNow(query: "hit", environment: environment)
        XCTAssertEqual(controller.sections.map(\.relativePath), ["a.md"])
        XCTAssertEqual(reads.count, 1 + IOSWorkspaceSearchLimits.truncationProbeFiles, reads.joined(separator: ","))
        XCTAssertTrue(controller.statusText.contains("Later files were not searched"), controller.statusText)
        XCTAssertFalse(controller.statusText.contains("Showing the first"), controller.statusText)

        reads.removeAll()
        let proving = IOSWorkspaceSearchController(maximumMatchesPerFile: 5, maximumMatchesPerQuery: 1)
        let untouched = (0 ..< 20).map { ShellFixtures.entry(String(format: "z%02d.md", $0)) }
        let provingEnvironment = IOSWorkspaceSearchEnvironment(
            scope: .directory,
            entries: [ShellFixtures.entry("a.md"), ShellFixtures.entry("b.md")] + untouched,
            openDocument: nil,
            read: { location async throws -> String in
                reads.append(location.relativePath)
                return location.relativePath == "a.md" || location.relativePath == "b.md" ? "hit" : "none"
            }
        )
        await proving.searchNow(query: "hit", environment: provingEnvironment)
        XCTAssertEqual(reads, ["a.md", "b.md"])
        XCTAssertTrue(proving.statusText.contains("Showing the first 1 matches"), proving.statusText)
        XCTAssertFalse(proving.statusText.contains("Later files were not searched"), proving.statusText)
    }

    func testSameTreeRefreshReusesReadsAndFileChangesOnlyRereadTheChangedPath() async {
        let entry = ShellFixtures.entry("posts/b.md")
        let other = ShellFixtures.entry("posts/c.md")
        let entries = [entry, other]
        let workspace = SearchWorkspaceDouble()
        var text = "old hit"
        var reads: [String] = []
        let facade = FakeSceneFacade(
            snapshot: ShellFixtures.sceneSnapshot(workspace: ShellFixtures.workspace(entries: entries)),
            capabilities: IOSSceneCapabilities(
                editor: nil, documents: nil, workspace: workspace, preview: nil, assets: nil
            )
        )
        let scene = IOSShellSceneState(
            facade: facade,
            surfaces: IOSShellFeatureSurfaces(
                currentGrant: { ShellFixtures.grant() },
                readWorkspaceDocument: { location in
                    reads.append(location.relativePath)
                    return location.relativePath == entry.location.relativePath ? text : "unchanged"
                }
            )
        )
        scene.startObserving()
        defer { scene.stopObserving() }
        scene.presentWorkspaceSearch()
        await scene.workspaceSearch.searchNow(query: "hit", environment: scene.workspaceSearchEnvironment())
        XCTAssertEqual(reads, ["posts/b.md", "posts/c.md"])
        XCTAssertEqual(scene.workspaceSearch.sections.map(\.relativePath), ["posts/b.md"])

        text = "fresh hit"
        workspace.emit(.resourceChanged(entry.location))
        await waitForIdle(scene.workspaceSearch)
        XCTAssertEqual(reads, ["posts/b.md", "posts/c.md", "posts/b.md"])
        XCTAssertEqual(scene.workspaceSearch.sections.first?.hits.map(\.matchedText), ["hit"])

        for _ in 0 ..< 5 {
            workspace.emit(.snapshotChanged(IOSWorkspaceSnapshot(
                workspaceID: entry.location.workspaceID,
                accessGeneration: entry.location.accessGeneration,
                requestID: UUID(),
                entries: entries
            )))
        }
        await waitForIdle(scene.workspaceSearch)
        XCTAssertEqual(reads, ["posts/b.md", "posts/c.md", "posts/b.md"])
        XCTAssertEqual(scene.workspaceSearch.sections.map(\.relativePath), ["posts/b.md"])

        text = "fresh"
        for _ in 0 ..< 5 {
            workspace.emit(.resourceChanged(entry.location))
        }
        await waitForIdle(scene.workspaceSearch)
        XCTAssertEqual(reads, ["posts/b.md", "posts/c.md", "posts/b.md", "posts/b.md"])
        XCTAssertTrue(scene.workspaceSearch.sections.isEmpty)
    }

    private func waitForIdle(_ controller: IOSWorkspaceSearchController) async {
        for _ in 0 ..< 200 where controller.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isSearching)
    }
}

@MainActor
private final class SearchWorkspaceDouble: IOSWorkspaceAccessProviding {
    private var observations: [(FakeObservation, @MainActor (IOSWorkspaceEvent) -> Void)] = []

    func emit(_ event: IOSWorkspaceEvent) {
        for (token, handler) in observations where !token.isCancelled {
            handler(event)
        }
    }

    func observe(_ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation {
        let token = FakeObservation()
        observations.append((token, handler))
        return token
    }

    func open(selectedURL _: URL, scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        throw IOSWorkspaceFailure.unavailable
    }

    func restore(bookmark _: Data, scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        throw IOSWorkspaceFailure.unavailable
    }

    func acquireLease(for _: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        throw IOSWorkspaceFailure.unavailable
    }

    func invalidate(_: IOSWorkspaceIdentity) -> UInt64 {
        0
    }

    func snapshot(for _: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        nil
    }

    func refresh(_: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        throw IOSWorkspaceFailure.unavailable
    }
}
