import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WorkspaceSearchSelectionTests: XCTestCase {
    func testOrderedRowIDsFollowPathAndSourceRangeOrder() {
        let presentation = makePresentation(rows: [
            ("a.md", 0, 1),
            ("a.md", 5, 1),
            ("b.md", 0, 2),
        ], generation: 3)
        let ordered = WorkspaceSearchSelectionNavigation.orderedRowIDs(in: presentation)
        XCTAssertEqual(ordered.count, 3)
        XCTAssertEqual(ordered[0].matchLocation, 0)
        XCTAssertEqual(ordered[0].ordinal, 0)
        XCTAssertEqual(ordered[1].matchLocation, 5)
        XCTAssertEqual(ordered[2].pathUTF8, Data("b.md".utf8))
    }

    func testSelectFirstAndLast() {
        let ids = makeIDs(count: 3, generation: 1)
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: nil,
                action: .selectFirst,
                orderedIDs: ids,
                queryGeneration: 1
            ),
            ids[0]
        )
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: nil,
                action: .selectLast,
                orderedIDs: ids,
                queryGeneration: 1
            ),
            ids[2]
        )
        XCTAssertNil(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[0],
                action: .selectFirst,
                orderedIDs: [],
                queryGeneration: 1
            )
        )
    }

    func testMoveDownAndUpDoNotWrap() {
        let ids = makeIDs(count: 3, generation: 2)

        // No selection → down selects first, up selects last.
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: nil,
                action: .moveDown,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[0]
        )
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: nil,
                action: .moveUp,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[2]
        )

        // Interior movement.
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[0],
                action: .moveDown,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[1]
        )
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[1],
                action: .moveUp,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[0]
        )

        // Ends do not wrap.
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[2],
                action: .moveDown,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[2]
        )
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[0],
                action: .moveUp,
                orderedIDs: ids,
                queryGeneration: 2
            ),
            ids[0]
        )
    }

    func testStaleGenerationClearsResolvedSelectionAndRestartsNavigation() {
        let generation: UInt64 = 4
        let current = makeIDs(count: 2, generation: generation)
        let stale = makeIDs(count: 2, generation: generation + 1)[0]

        XCTAssertNil(
            WorkspaceSearchSelectionNavigation.resolvedSelection(
                stale,
                orderedIDs: current,
                queryGeneration: generation
            )
        )

        // Stale selection behaves as empty for moveDown → first of current generation.
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: stale,
                action: .moveDown,
                orderedIDs: current,
                queryGeneration: generation
            ),
            current[0]
        )
    }

    func testClearAndMissingID() {
        let ids = makeIDs(count: 2, generation: 5)
        XCTAssertNil(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: ids[0],
                action: .clear,
                orderedIDs: ids,
                queryGeneration: 5
            )
        )

        let orphan = WorkspaceSearchResultRowID(
            relativePath: "missing.md",
            queryGeneration: 5,
            match: TextSearchMatch(
                range: NSRange(location: 0, length: 1),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            ),
            ordinal: 0
        )
        XCTAssertNil(
            WorkspaceSearchSelectionNavigation.resolvedSelection(
                orphan,
                orderedIDs: ids,
                queryGeneration: 5
            )
        )
        // Orphan treated as empty → selectFirst via moveDown.
        XCTAssertEqual(
            WorkspaceSearchSelectionNavigation.reduce(
                selection: orphan,
                action: .moveDown,
                orderedIDs: ids,
                queryGeneration: 5
            ),
            ids[0]
        )
    }

    func testReturnActivationOnlyWhenStateStillHoldsResult() {
        let generation: UInt64 = 7
        let context = WorkspaceSearchContext(
            rootIdentity: "/tmp",
            workspaceGeneration: 1,
            queryGeneration: generation
        )
        let match = TextSearchMatch(
            range: NSRange(location: 0, length: 1),
            line: 1,
            preview: "x",
            previewMatchRange: NSRange(location: 0, length: 1)
        )
        let rowID = WorkspaceSearchResultRowID(
            relativePath: "a.md",
            queryGeneration: generation,
            match: match,
            ordinal: 0
        )

        // No authority → cannot activate (Return must no-op).
        let noAuthority = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "x"),
            queryGeneration: generation,
            activeContext: context,
            phase: .completed,
            fileResults: [
                WorkspaceSearchFileResult(
                    relativePath: "a.md",
                    contentFingerprint: WorkspaceSearchContentFingerprint(text: "x"),
                    matches: [match],
                    isTruncated: false,
                    fileAuthority: nil
                ),
            ]
        )
        XCTAssertNil(
            WorkspaceSearchResultsPresenter.activationLookup(
                rowID: rowID,
                searchState: noAuthority
            )
        )

        // Generation advanced after rapid query replace → old selection invalid.
        let replaced = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "y"),
            queryGeneration: generation + 1,
            activeContext: WorkspaceSearchContext(
                rootIdentity: "/tmp",
                workspaceGeneration: 1,
                queryGeneration: generation + 1
            ),
            phase: .completed,
            fileResults: []
        )
        XCTAssertNil(
            WorkspaceSearchResultsPresenter.activationLookup(
                rowID: rowID,
                searchState: replaced
            )
        )
        XCTAssertNil(
            WorkspaceSearchSelectionNavigation.resolvedSelection(
                rowID,
                orderedIDs: WorkspaceSearchSelectionNavigation.orderedRowIDs(
                    in: WorkspaceSearchResultsPresenter.make(
                        searchState: replaced,
                        queryText: "y",
                        canUseWorkspaceSearch: true,
                        isWorkspaceSearchReady: true
                    )
                ),
                queryGeneration: generation + 1
            )
        )
    }

    func testAccessibilityIdentifierAndLabelFormat() {
        let rowID = WorkspaceSearchResultRowID(
            relativePath: "docs/note.md",
            queryGeneration: 9,
            match: TextSearchMatch(
                range: NSRange(location: 4, length: 3),
                line: 12,
                preview: "hello world",
                previewMatchRange: NSRange(location: 0, length: 5)
            ),
            ordinal: 1
        )

        let identifier = WorkspaceSearchAccessibility.row(rowID)
        XCTAssertTrue(identifier.hasPrefix("plainsong.workspaceSearch.row."))
        XCTAssertTrue(identifier.contains(".g9."))
        XCTAssertTrue(identifier.contains(".l4."))
        XCTAssertTrue(identifier.contains(".n3."))
        XCTAssertTrue(identifier.hasSuffix(".o1"))
        // Path token is UTF-8 hex, not raw String identity.
        XCTAssertTrue(identifier.contains(Data("docs/note.md".utf8).map { String(format: "%02x", $0) }.joined()))

        let nfc = WorkspaceSearchAccessibility.row(
            WorkspaceSearchResultRowID(
                relativePath: "caf\u{00E9}.md",
                queryGeneration: 1,
                match: TextSearchMatch(
                    range: NSRange(location: 0, length: 1),
                    line: 1,
                    preview: "x",
                    previewMatchRange: NSRange(location: 0, length: 1)
                ),
                ordinal: 0
            )
        )
        let nfd = WorkspaceSearchAccessibility.row(
            WorkspaceSearchResultRowID(
                relativePath: "cafe\u{0301}.md",
                queryGeneration: 1,
                match: TextSearchMatch(
                    range: NSRange(location: 0, length: 1),
                    line: 1,
                    preview: "x",
                    previewMatchRange: NSRange(location: 0, length: 1)
                ),
                ordinal: 0
            )
        )
        XCTAssertNotEqual(nfc, nfd)

        let label = WorkspaceSearchAccessibility.rowLabel(
            relativePath: "docs/note.md",
            lineNumber: 12,
            snippet: "hello world"
        )
        XCTAssertEqual(label, "docs/note.md, line 12, hello world")
        XCTAssertTrue(label.contains("docs/note.md"))
        XCTAssertTrue(label.contains("12"))
        XCTAssertTrue(label.contains("hello world"))

        XCTAssertEqual(WorkspaceSearchAccessibility.rowValue(canActivate: true), "Available")
        XCTAssertEqual(WorkspaceSearchAccessibility.rowValue(canActivate: false), "Unavailable")

        // Single source of truth with the AppKit query-field stamp (no duplicated literal drift).
        XCTAssertEqual(
            WorkspaceSearchAccessibility.queryField,
            WorkspaceSearchFieldFocus.accessibilityIdentifier
        )
        XCTAssertEqual(WorkspaceSearchAccessibility.queryField, "plainsong.workspaceSearch.queryField")
        XCTAssertEqual(WorkspaceSearchAccessibility.modePicker, "plainsong.workspaceSearch.mode")
        XCTAssertEqual(WorkspaceSearchAccessibility.matchCase, "plainsong.workspaceSearch.matchCase")
        XCTAssertEqual(WorkspaceSearchAccessibility.wholeWord, "plainsong.workspaceSearch.wholeWord")
        XCTAssertEqual(WorkspaceSearchAccessibility.resultsList, "plainsong.workspaceSearch.results")
        XCTAssertEqual(WorkspaceSearchAccessibility.status, "plainsong.workspaceSearch.status")

        XCTAssertEqual(
            WorkspaceSearchAccessibility.statusLabel(.noResults),
            "No Results"
        )
        XCTAssertEqual(
            WorkspaceSearchAccessibility.bannerLabel(.globalTruncation),
            "Results truncated because the global match limit was reached"
        )
        XCTAssertTrue(
            WorkspaceSearchAccessibility.bannerLabel(
                .skipped(count: 2, detailLines: ["a — oversized"], omittedDetailCount: 1)
            ).contains("Skipped 2 files")
        )
    }

    func testEditorFocusAndSearchFocusRemainIndependentOfSearchSelection() {
        // Command-F remains reserved for unfinished editor find. Search selection / Command-Shift-F
        // use separate tokens. Escaping the search field calls `requestEditorFocus()` without
        // clearing search UI state.
        let appState = AppState()
        let beforeEditor = appState.editorFocusRequestID
        let beforeSearchFocus = appState.workspaceSearchUI.focusRequestID
        let beforeQuery = appState.workspaceSearchUI.queryText
        let beforeMode = appState.workspaceSearchUI.mode

        appState.requestEditorFocus()
        XCTAssertEqual(appState.editorFocusRequestID, beforeEditor + 1)
        XCTAssertEqual(
            appState.workspaceSearchUI.focusRequestID,
            beforeSearchFocus,
            "Editor focus must not advance search focus tokens"
        )
        XCTAssertEqual(appState.workspaceSearchUI.queryText, beforeQuery)
        XCTAssertEqual(appState.workspaceSearchUI.mode, beforeMode)

        // Selection navigation remains pure and does not touch editor focus tokens.
        let ids = makeIDs(count: 2, generation: 1)
        _ = WorkspaceSearchSelectionNavigation.reduce(
            selection: nil,
            action: .selectFirst,
            orderedIDs: ids,
            queryGeneration: 1
        )
        XCTAssertEqual(appState.editorFocusRequestID, beforeEditor + 1)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, beforeSearchFocus)
    }

    // MARK: - Helpers

    private func makeIDs(count: Int, generation: UInt64) -> [WorkspaceSearchResultRowID] {
        (0 ..< count).map { index in
            WorkspaceSearchResultRowID(
                relativePath: "f\(index).md",
                queryGeneration: generation,
                match: TextSearchMatch(
                    range: NSRange(location: index * 10, length: 1),
                    line: index + 1,
                    preview: "m\(index)",
                    previewMatchRange: NSRange(location: 0, length: 1)
                ),
                ordinal: 0
            )
        }
    }

    private func makePresentation(
        rows: [(path: String, location: Int, length: Int)],
        generation: UInt64
    ) -> WorkspaceSearchResultsPresentation {
        // Group consecutive same-path rows into sections (caller supplies path order).
        var sections: [WorkspaceSearchResultFileSectionModel] = []
        var currentPath: String?
        var currentRows: [WorkspaceSearchResultRowModel] = []
        var ordinal = 0

        func flush() {
            guard let path = currentPath else { return }
            let pathUTF8 = Data(path.utf8)
            sections.append(
                WorkspaceSearchResultFileSectionModel(
                    id: WorkspaceSearchResultFileSectionID(
                        pathUTF8: pathUTF8,
                        queryGeneration: generation
                    ),
                    relativePath: path,
                    matchCount: currentRows.count,
                    isTruncated: false,
                    canActivate: true,
                    rows: currentRows
                )
            )
            currentRows = []
            ordinal = 0
        }

        for row in rows {
            if currentPath != row.path {
                flush()
                currentPath = row.path
            }
            let match = TextSearchMatch(
                range: NSRange(location: row.location, length: row.length),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            )
            currentRows.append(
                WorkspaceSearchResultRowModel(
                    id: WorkspaceSearchResultRowID(
                        pathUTF8: Data(row.path.utf8),
                        queryGeneration: generation,
                        match: match,
                        ordinal: ordinal
                    ),
                    lineNumber: 1,
                    snippet: "x",
                    previewMatchRange: match.previewMatchRange,
                    canActivate: true
                )
            )
            ordinal += 1
        }
        flush()

        return WorkspaceSearchResultsPresentation(
            status: .hidden,
            sections: sections,
            banners: [],
            showsRetry: false
        )
    }
}
