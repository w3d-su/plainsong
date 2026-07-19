import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WorkspaceSearchResultsPresentationTests: XCTestCase {
    func testPhaseMappingToPresentationStates() {
        let emptyQuery = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(),
            queryText: "",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(
            emptyQuery.status,
            .prompt("Type to search Markdown and MDX files.")
        )

        let waiting = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 1,
                phase: .debouncing
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(waiting.status, .waiting)

        let searching = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 2,
                phase: .searching,
                progress: WorkspaceSearchProgress(completedFileCount: 3, candidateFileCount: 10)
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(
            searching.status,
            .searching(completedFileCount: 3, candidateFileCount: 10)
        )

        let noResults = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 3,
                phase: .completed,
                summary: emptySummary(candidateFileCount: 2, searchedFileCount: 2)
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(noResults.status, .noResults)
        XCTAssertTrue(noResults.sections.isEmpty)

        let withResults = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 4,
                phase: .completed,
                fileResults: [fileResult(path: "a.md", needle: "x", text: "x line")],
                summary: emptySummary(
                    candidateFileCount: 1,
                    searchedFileCount: 1,
                    totalEmittedMatchCount: 1
                )
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(withResults.status, .hidden)
        XCTAssertEqual(withResults.sections.count, 1)
        XCTAssertEqual(withResults.sections[0].relativePath, "a.md")
        XCTAssertEqual(withResults.sections[0].matchCount, 1)

        let validation = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                queryGeneration: 5,
                phase: .validationFailure(.newlineInQuery)
            ),
            queryText: "a\nb",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        guard case let .validationFailure(message) = validation.status else {
            return XCTFail("expected validation failure")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("newline"))

        let overlong = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                queryGeneration: 6,
                phase: .validationFailure(.overlongQuery(maximumUTF16Length: 256))
            ),
            queryText: String(repeating: "a", count: 300),
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        guard case let .validationFailure(overlongMessage) = overlong.status else {
            return XCTFail("expected overlong validation")
        }
        XCTAssertTrue(overlongMessage.contains("256"))
    }

    func testPartialResultsRetainedWhileSearchingAndOnServiceFailure() {
        let partial = fileResult(path: "a.md", needle: "x", text: "x")
        let searching = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 1,
                phase: .searching,
                fileResults: [partial],
                progress: WorkspaceSearchProgress(completedFileCount: 1, candidateFileCount: 5)
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        XCTAssertEqual(searching.sections.count, 1)
        XCTAssertEqual(searching.sections[0].rows.count, 1)

        let failed = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 1,
                phase: .serviceFailure(.unexpectedProducerFailure),
                fileResults: [partial]
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
        guard case .serviceFailure = failed.status else {
            return XCTFail("expected service failure status")
        }
        XCTAssertTrue(failed.showsRetry)
        XCTAssertEqual(failed.sections.count, 1, "partial results must not be cleared on error")
        XCTAssertNotEqual(failed.status, .noResults)
    }

    func testSkippedOmittedAndTruncationBanners() {
        let skipped = [
            WorkspaceSearchSkippedFile(relativePath: "big.md", reason: .oversized(byteCount: 999_999)),
            WorkspaceSearchSkippedFile(relativePath: "bad.md", reason: .invalidUTF8),
        ]
        let summary = WorkspaceSearchSummary(
            candidateFileCount: 10,
            searchedFileCount: 7,
            skippedFileCount: 5,
            ignoredFileCount: 0,
            totalEmittedMatchCount: 2,
            truncatedFilePaths: ["a.md", "b.md"],
            isGloballyTruncated: true,
            skippedFiles: skipped,
            omittedSkippedFileCount: 3,
            readInstrumentation: zeroInstrumentation
        )
        let presentation = WorkspaceSearchResultsPresenter.make(
            searchState: WorkspaceSearchState(
                activeQuery: TextSearchQuery(pattern: "x"),
                queryGeneration: 2,
                phase: .completed,
                fileResults: [
                    fileResult(path: "a.md", needle: "x", text: "x", truncated: true),
                ],
                summary: summary
            ),
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )

        XCTAssertTrue(
            presentation.banners.contains {
                if case let .skipped(count, details, omitted) = $0 {
                    return count == 5 && details.count == 2 && omitted == 3
                }
                return false
            }
        )
        XCTAssertTrue(presentation.banners.contains(.globalTruncation))
        XCTAssertTrue(presentation.sections[0].isTruncated)
    }

    func testNFDAndNFCPathsProduceDistinctRowIDs() {
        let nfd = "cafe\u{0301}.md" // e + combining acute
        let nfcPath = "caf\u{00E9}.md" // precomposed é
        XCTAssertNotEqual(Data(nfcPath.utf8), Data(nfd.utf8))

        let match = TextSearchMatch(
            range: NSRange(location: 0, length: 1),
            line: 1,
            preview: "x",
            previewMatchRange: NSRange(location: 0, length: 1)
        )
        let idNFC = WorkspaceSearchResultRowID(
            relativePath: nfcPath,
            queryGeneration: 1,
            match: match,
            ordinal: 0
        )
        let idNFD = WorkspaceSearchResultRowID(
            relativePath: nfd,
            queryGeneration: 1,
            match: match,
            ordinal: 0
        )
        XCTAssertNotEqual(idNFC, idNFD)
        XCTAssertNotEqual(idNFC.pathUTF8, idNFD.pathUTF8)

        let sectionNFC = WorkspaceSearchResultFileSectionID(
            relativePath: nfcPath,
            queryGeneration: 1
        )
        let sectionNFD = WorkspaceSearchResultFileSectionID(
            relativePath: nfd,
            queryGeneration: 1
        )
        XCTAssertNotEqual(sectionNFC, sectionNFD)
    }

    func testUTF16SnippetHighlightCoversEmojiAndCombiningMarks() {
        // "a👍b" — thumbs up is two UTF-16 units
        let snippet = "a👍b"
        let matchRange = NSRange(location: 1, length: 2)
        let attributed = WorkspaceSearchSnippetHighlight.attributedSnippet(
            snippet,
            matchRange: matchRange
        )
        XCTAssertEqual(String(attributed.characters), snippet)

        // Combining mark: e\u{0301} is two UTF-16 units in NFD form inside preview.
        let combining = "xe\u{0301}y"
        let combiningRange = NSRange(location: 1, length: 2)
        let combiningAttributed = WorkspaceSearchSnippetHighlight.attributedSnippet(
            combining,
            matchRange: combiningRange
        )
        XCTAssertEqual(String(combiningAttributed.characters), combining)

        // Out-of-bounds range falls back to plain text without trapping.
        let safe = WorkspaceSearchSnippetHighlight.attributedSnippet(
            "hi",
            matchRange: NSRange(location: 10, length: 2)
        )
        XCTAssertEqual(String(safe.characters), "hi")
    }

    func testActivationLookupRejectsStaleGenerationMissingAuthorityAndRangeMismatch() {
        let generation: UInt64 = 9
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
        let authorized = WorkspaceSearchFileResult(
            relativePath: "a.md",
            contentFingerprint: WorkspaceSearchContentFingerprint(text: "x"),
            matches: [match],
            isTruncated: false,
            fileAuthority: nil
        )
        let state = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "x"),
            queryGeneration: generation,
            activeContext: context,
            phase: .completed,
            fileResults: [authorized]
        )
        let rowID = WorkspaceSearchResultRowID(
            relativePath: "a.md",
            queryGeneration: generation,
            match: match,
            ordinal: 0
        )

        // No authority → cannot activate.
        XCTAssertNil(
            WorkspaceSearchResultsPresenter.activationLookup(rowID: rowID, searchState: state)
        )

        // Stale generation.
        let staleID = WorkspaceSearchResultRowID(
            relativePath: "a.md",
            queryGeneration: generation + 1,
            match: match,
            ordinal: 0
        )
        XCTAssertNil(
            WorkspaceSearchResultsPresenter.activationLookup(rowID: staleID, searchState: state)
        )

        // Range mismatch after ordinal reuse.
        let mismatched = WorkspaceSearchResultRowID(
            relativePath: "a.md",
            queryGeneration: generation,
            match: TextSearchMatch(
                range: NSRange(location: 5, length: 1),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            ),
            ordinal: 0
        )
        XCTAssertNil(
            WorkspaceSearchResultsPresenter.activationLookup(rowID: mismatched, searchState: state)
        )
    }

    func testActivationLookupSucceedsForAuthorityBackedExactMatch() throws {
        let generation: UInt64 = 3
        let context = WorkspaceSearchContext(
            rootIdentity: "/workspace",
            workspaceGeneration: 2,
            queryGeneration: generation
        )
        let match = TextSearchMatch(
            range: NSRange(location: 2, length: 3),
            line: 4,
            preview: "…abc…",
            previewMatchRange: NSRange(location: 1, length: 3)
        )

        // Build a real authority so canActivate is true.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws3c-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("a.md")
        try "xxabc".write(to: fileURL, atomically: true, encoding: .utf8)
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try rootAuthority.canonicalizedLocation(forFileURL: fileURL)
        guard case let .regular(identity) = WorkspaceNoFollowFileInspector.status(at: location) else {
            return XCTFail("expected regular file identity")
        }
        let authority = WorkspaceSearchFileAuthority(location: location, identity: identity)

        let fileResult = WorkspaceSearchFileResult(
            relativePath: "a.md",
            contentFingerprint: WorkspaceSearchContentFingerprint(text: "xxabc"),
            matches: [match],
            isTruncated: false,
            fileAuthority: authority
        )
        let state = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "abc"),
            queryGeneration: generation,
            activeContext: context,
            phase: .completed,
            fileResults: [fileResult]
        )
        let rowID = WorkspaceSearchResultRowID(
            relativePath: "a.md",
            queryGeneration: generation,
            match: match,
            ordinal: 0
        )
        let payload = try XCTUnwrap(
            WorkspaceSearchResultsPresenter.activationLookup(rowID: rowID, searchState: state)
        )
        XCTAssertEqual(payload.context, context)
        XCTAssertEqual(payload.fileResult, fileResult)
        XCTAssertEqual(payload.match, match)
        XCTAssertNotNil(payload.fileResult.fileAuthority)
    }

    func testPresentationInputsEqualityDetectsInPlaceSameCountRewrites() {
        let match = TextSearchMatch(
            range: NSRange(location: 0, length: 1),
            line: 1,
            preview: "a match",
            previewMatchRange: NSRange(location: 0, length: 1)
        )
        let state = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "x"),
            queryGeneration: 7,
            phase: .searching,
            fileResults: [
                WorkspaceSearchFileResult(
                    relativePath: "a.md",
                    contentFingerprint: WorkspaceSearchContentFingerprint(text: "a"),
                    matches: [match],
                    isTruncated: false,
                    fileAuthority: nil
                ),
            ],
            skippedFiles: [
                WorkspaceSearchSkippedFile(relativePath: "s.md", reason: .unreadable),
            ],
            progress: WorkspaceSearchProgress(completedFileCount: 1, candidateFileCount: 3)
        )
        let baseline = inputs(for: state)
        XCTAssertEqual(baseline, inputs(for: state), "identical inputs must not rebuild")
        XCTAssertEqual(
            WorkspaceSearchResultsPresenter.make(baseline),
            WorkspaceSearchResultsPresenter.make(
                searchState: state,
                queryText: "x",
                canUseWorkspaceSearch: true,
                isWorkspaceSearchReady: true
            ),
            "inputs overload must match the expanded make"
        )

        // Same-path, same-match-count in-place replacement (different range/snippet): the
        // generation/phase/count heuristic this memo replaced would miss exactly this.
        var replacedFile = state
        replacedFile.fileResults[0] = WorkspaceSearchFileResult(
            relativePath: "a.md",
            contentFingerprint: WorkspaceSearchContentFingerprint(text: "b"),
            matches: [
                TextSearchMatch(
                    range: NSRange(location: 5, length: 1),
                    line: 2,
                    preview: "b match",
                    previewMatchRange: NSRange(location: 0, length: 1)
                ),
            ],
            isTruncated: false,
            fileAuthority: nil
        )
        XCTAssertNotEqual(baseline, inputs(for: replacedFile))

        // Same-count skipped-file reason rewrite must also rebuild (banner detail text).
        var rewrittenSkip = state
        rewrittenSkip.skippedFiles[0] = WorkspaceSearchSkippedFile(
            relativePath: "s.md",
            reason: .invalidUTF8
        )
        XCTAssertNotEqual(baseline, inputs(for: rewrittenSkip))
    }

    func testPresentationInputsEqualityDetectsChromeProgressAndPhaseChanges() {
        let state = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "x"),
            queryGeneration: 1,
            phase: .searching
        )
        let baseline = inputs(for: state)

        var progressed = state
        progressed.progress = WorkspaceSearchProgress(completedFileCount: 2, candidateFileCount: 9)
        XCTAssertNotEqual(baseline, inputs(for: progressed))

        var completed = state
        completed.phase = .completed
        XCTAssertNotEqual(baseline, inputs(for: completed))

        XCTAssertNotEqual(
            baseline,
            WorkspaceSearchResultsPresentationInputs(
                searchState: state,
                queryText: "xy",
                canUseWorkspaceSearch: true,
                isWorkspaceSearchReady: true
            )
        )
        XCTAssertNotEqual(
            baseline,
            WorkspaceSearchResultsPresentationInputs(
                searchState: state,
                queryText: "x",
                canUseWorkspaceSearch: false,
                isWorkspaceSearchReady: false
            )
        )
        XCTAssertNotEqual(
            baseline,
            WorkspaceSearchResultsPresentationInputs(
                searchState: state,
                queryText: "x",
                canUseWorkspaceSearch: true,
                isWorkspaceSearchReady: false
            )
        )
    }

    // MARK: - Helpers

    private func inputs(for state: WorkspaceSearchState) -> WorkspaceSearchResultsPresentationInputs {
        WorkspaceSearchResultsPresentationInputs(
            searchState: state,
            queryText: "x",
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
    }

    private var zeroInstrumentation: WorkspaceSearchReadInstrumentation {
        WorkspaceSearchReadInstrumentation(
            diskReadCount: 0,
            diskReadByteCount: 0,
            maximumConcurrentReads: 0,
            maximumBufferedReadCount: 0,
            maximumOutstandingReadCount: 0
        )
    }

    private func emptySummary(
        candidateFileCount: Int,
        searchedFileCount: Int,
        totalEmittedMatchCount: Int = 0
    ) -> WorkspaceSearchSummary {
        WorkspaceSearchSummary(
            candidateFileCount: candidateFileCount,
            searchedFileCount: searchedFileCount,
            skippedFileCount: 0,
            ignoredFileCount: 0,
            totalEmittedMatchCount: totalEmittedMatchCount,
            truncatedFilePaths: [],
            isGloballyTruncated: false,
            skippedFiles: [],
            omittedSkippedFileCount: 0,
            readInstrumentation: zeroInstrumentation
        )
    }

    private func fileResult(
        path: String,
        needle: String,
        text: String,
        truncated: Bool = false
    ) -> WorkspaceSearchFileResult {
        let ns = text as NSString
        let range = ns.range(of: needle)
        let match = TextSearchMatch(
            range: range,
            line: 1,
            preview: text,
            previewMatchRange: NSRange(location: 0, length: min(needle.utf16.count, text.utf16.count))
        )
        return WorkspaceSearchFileResult(
            relativePath: path,
            contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
            matches: [match],
            isTruncated: truncated,
            fileAuthority: nil
        )
    }
}
