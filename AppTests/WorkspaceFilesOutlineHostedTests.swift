import AppKit
@testable import Plainsong
import XCTest

/// Files rows skip re-rendering through `.equatable()`, but a folder row must stay a bare
/// `DisclosureGroup`: inside an `EquatableView`, `List` drew it as a plain row without a
/// disclosure triangle (caught by `WorkspaceSearchAcceptanceTests` on CI).
@MainActor
extension EditorFindHostedGateTests {
    func testFolderRowsInTheFilesOutlineStayExpandable() async throws {
        let fixture = try makeWorkspaceFixture(files: [
            "a.md": "# A",
            "posts/b.md": "# B",
            "posts/drafts/c.md": "# C",
        ])
        let appState = fixture.appState
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace opens") { appState.shownSession.fileURL != nil }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)

        let outline = try await waitForView(NSOutlineView.self, in: host.window)
        try await waitUntil("Files rows load") { outline.numberOfRows >= 3 }
        let expandableRows = (0 ..< outline.numberOfRows).filter { row in
            outline.item(atRow: row).map { outline.isExpandable($0) } ?? false
        }
        // The workspace root and `posts` (collapsed, so `drafts` is not a row yet).
        XCTAssertGreaterThanOrEqual(expandableRows.count, 2, "folder rows lost their disclosure triangle")
    }
}
