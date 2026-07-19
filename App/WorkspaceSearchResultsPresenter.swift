import Foundation
import MarkdownCore
import WorkspaceKit

// MARK: - Mapping

enum WorkspaceSearchResultsPresenter {
    /// Convenience for memoized callers holding exact presenter inputs.
    static func make(
        _ inputs: WorkspaceSearchResultsPresentationInputs
    ) -> WorkspaceSearchResultsPresentation {
        make(
            searchState: inputs.searchState,
            queryText: inputs.queryText,
            canUseWorkspaceSearch: inputs.canUseWorkspaceSearch,
            isWorkspaceSearchReady: inputs.isWorkspaceSearchReady
        )
    }

    /// Maps App search + chrome readiness into a pure presentation model.
    ///
    /// Partial `fileResults` are preserved for searching and service-failure phases so an error
    /// never masquerades as zero results.
    static func make(
        searchState: WorkspaceSearchState,
        queryText: String,
        canUseWorkspaceSearch: Bool,
        isWorkspaceSearchReady: Bool
    ) -> WorkspaceSearchResultsPresentation {
        if !canUseWorkspaceSearch {
            return WorkspaceSearchResultsPresentation(
                status: .prompt("Open a folder workspace to search."),
                sections: [],
                banners: [],
                showsRetry: false
            )
        }

        if !isWorkspaceSearchReady {
            return WorkspaceSearchResultsPresentation(
                status: .prompt("Preparing workspace…"),
                sections: [],
                banners: [],
                showsRetry: false
            )
        }

        if queryText.isEmpty {
            return WorkspaceSearchResultsPresentation(
                status: .prompt("Type to search Markdown and MDX files."),
                sections: [],
                banners: [],
                showsRetry: false
            )
        }

        let generation = searchState.queryGeneration
        let sections = makeSections(
            fileResults: searchState.fileResults,
            queryGeneration: generation
        )

        switch searchState.phase {
        case .idle:
            // Non-empty chrome with idle phase (e.g. after invalidation without refresh).
            return WorkspaceSearchResultsPresentation(
                status: sections.isEmpty ? .prompt("Type to search Markdown and MDX files.") : .hidden,
                sections: sections,
                banners: makeBanners(searchState: searchState),
                showsRetry: false
            )

        case .debouncing:
            return WorkspaceSearchResultsPresentation(
                status: .waiting,
                sections: sections,
                banners: [],
                showsRetry: false
            )

        case .searching:
            let progress = searchState.progress
            return WorkspaceSearchResultsPresentation(
                status: .searching(
                    completedFileCount: progress?.completedFileCount ?? 0,
                    candidateFileCount: progress?.candidateFileCount ?? 0
                ),
                sections: sections,
                banners: makeBanners(searchState: searchState),
                showsRetry: false
            )

        case .completed:
            let banners = makeBanners(searchState: searchState)
            if sections.isEmpty {
                return WorkspaceSearchResultsPresentation(
                    status: .noResults,
                    sections: [],
                    banners: banners,
                    showsRetry: false
                )
            }
            return WorkspaceSearchResultsPresentation(
                status: .hidden,
                sections: sections,
                banners: banners,
                showsRetry: false
            )

        case let .validationFailure(error):
            return WorkspaceSearchResultsPresentation(
                status: .validationFailure(validationMessage(error)),
                sections: [],
                banners: [],
                showsRetry: false
            )

        case let .serviceFailure(failure):
            // Keep partial results; do not present as an empty successful search.
            return WorkspaceSearchResultsPresentation(
                status: .serviceFailure(serviceFailureMessage(failure)),
                sections: sections,
                banners: makeBanners(searchState: searchState),
                showsRetry: true
            )
        }
    }

    static func makeSections(
        fileResults: [WorkspaceSearchFileResult],
        queryGeneration: UInt64
    ) -> [WorkspaceSearchResultFileSectionModel] {
        fileResults.map { fileResult in
            // One UTF-8 path buffer per section — shared by section ID and every match row.
            let pathUTF8 = Data(fileResult.relativePath.utf8)
            let canActivate = fileResult.fileAuthority != nil
            let rows: [WorkspaceSearchResultRowModel] = fileResult.matches.enumerated().map { ordinal, match in
                WorkspaceSearchResultRowModel(
                    id: WorkspaceSearchResultRowID(
                        pathUTF8: pathUTF8,
                        queryGeneration: queryGeneration,
                        match: match,
                        ordinal: ordinal
                    ),
                    lineNumber: match.line,
                    snippet: match.preview,
                    previewMatchRange: match.previewMatchRange,
                    canActivate: canActivate
                )
            }
            return WorkspaceSearchResultFileSectionModel(
                id: WorkspaceSearchResultFileSectionID(
                    pathUTF8: pathUTF8,
                    queryGeneration: queryGeneration
                ),
                relativePath: fileResult.relativePath,
                matchCount: fileResult.matches.count,
                isTruncated: fileResult.isTruncated,
                canActivate: canActivate,
                rows: rows
            )
        }
    }

    /// Resolves a row back to the live search payload for activation (no URL rebuild).
    static func activationLookup(
        rowID: WorkspaceSearchResultRowID,
        searchState: WorkspaceSearchState
    ) -> (
        context: WorkspaceSearchContext,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    )? {
        guard let context = searchState.activeContext,
              context.queryGeneration == rowID.queryGeneration,
              searchState.queryGeneration == rowID.queryGeneration
        else {
            return nil
        }

        guard let fileResult = searchState.fileResults.first(where: {
            Data($0.relativePath.utf8) == rowID.pathUTF8
        }) else {
            return nil
        }

        guard fileResult.fileAuthority != nil else {
            return nil
        }

        guard rowID.ordinal >= 0,
              rowID.ordinal < fileResult.matches.count
        else {
            return nil
        }

        let match = fileResult.matches[rowID.ordinal]
        guard match.range.location == rowID.matchLocation,
              match.range.length == rowID.matchLength
        else {
            return nil
        }

        return (context, fileResult, match)
    }

    // MARK: Private

    private static func makeBanners(
        searchState: WorkspaceSearchState
    ) -> [WorkspaceSearchBanner] {
        var banners: [WorkspaceSearchBanner] = []

        let skippedCount: Int
        let skippedDetails: [WorkspaceSearchSkippedFile]
        let omitted: Int

        if let summary = searchState.summary {
            skippedCount = summary.skippedFileCount
            skippedDetails = summary.skippedFiles
            omitted = summary.omittedSkippedFileCount
        } else {
            // During searching (or any pre-summary phase), surface retained skip details only.
            skippedCount = searchState.skippedFiles.count
            skippedDetails = searchState.skippedFiles
            omitted = 0
        }

        if skippedCount > 0 {
            let detailLines = skippedDetails.map(skipDetailLine)
            banners.append(
                .skipped(
                    count: skippedCount,
                    detailLines: detailLines,
                    omittedDetailCount: omitted
                )
            )
        }

        // Per-file truncation always lands in `truncatedFilePaths` (or summary equivalent);
        // global overflow sets `isGloballyTruncated`. Prefer the global banner when both apply.
        if searchState.isGloballyTruncated {
            banners.append(.globalTruncation)
        } else if !searchState.truncatedFilePaths.isEmpty {
            banners.append(.perFileTruncation(pathCount: searchState.truncatedFilePaths.count))
        }

        return banners
    }

    private static func skipDetailLine(_ skipped: WorkspaceSearchSkippedFile) -> String {
        "\(skipped.relativePath) — \(skipReasonDescription(skipped.reason))"
    }

    static func skipReasonDescription(_ reason: WorkspaceSearchSkipReason) -> String {
        switch reason {
        case .disappeared:
            "file disappeared"
        case .unreadable:
            "unreadable"
        case .invalidUTF8:
            "invalid UTF-8"
        case let .oversized(byteCount):
            "oversized (\(byteCount) bytes)"
        case .emptyPath:
            "empty path"
        case .absolutePath:
            "absolute path"
        case .pathTraversal:
            "path traversal"
        case .symlinkEscape:
            "symlink escape"
        case .unsupportedPhysicalFileKind:
            "unsupported file kind"
        }
    }

    static func validationMessage(_ error: WorkspaceSearchValidationError) -> String {
        switch error {
        case .emptyQuery:
            "Enter a search pattern."
        case .newlineInQuery:
            "Search pattern cannot contain a newline."
        case let .overlongQuery(maximumUTF16Length):
            "Search pattern is too long (max \(maximumUTF16Length) UTF-16 units)."
        }
    }

    static func serviceFailureMessage(_ failure: WorkspaceSearchServiceFailure) -> String {
        switch failure {
        case .unexpectedProducerFailure:
            "Search failed unexpectedly."
        }
    }
}
