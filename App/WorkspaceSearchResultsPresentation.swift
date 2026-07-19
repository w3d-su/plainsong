import Foundation
import MarkdownCore
import WorkspaceKit

// MARK: - Row / section identity (UTF-8 path bytes, not Swift String identity)

/// Stable file-group identity: exact relative-path UTF-8 bytes + query generation.
struct WorkspaceSearchResultFileSectionID: Hashable {
    let pathUTF8: Data
    let queryGeneration: UInt64

    init(pathUTF8: Data, queryGeneration: UInt64) {
        self.pathUTF8 = pathUTF8
        self.queryGeneration = queryGeneration
    }

    init(relativePath: String, queryGeneration: UInt64) {
        self.init(pathUTF8: Data(relativePath.utf8), queryGeneration: queryGeneration)
    }
}

/// Stable match-row identity. NFC/NFD paths stay distinct via UTF-8 path bytes.
struct WorkspaceSearchResultRowID: Hashable {
    let pathUTF8: Data
    let queryGeneration: UInt64
    let matchLocation: Int
    let matchLength: Int
    let ordinal: Int

    init(
        pathUTF8: Data,
        queryGeneration: UInt64,
        match: TextSearchMatch,
        ordinal: Int
    ) {
        self.pathUTF8 = pathUTF8
        self.queryGeneration = queryGeneration
        matchLocation = match.range.location
        matchLength = match.range.length
        self.ordinal = ordinal
    }

    init(
        relativePath: String,
        queryGeneration: UInt64,
        match: TextSearchMatch,
        ordinal: Int
    ) {
        self.init(
            pathUTF8: Data(relativePath.utf8),
            queryGeneration: queryGeneration,
            match: match,
            ordinal: ordinal
        )
    }
}

// MARK: - Presentation model

enum WorkspaceSearchStatusPresentation: Equatable {
    case hidden
    /// Idle / empty-query guidance (or no-folder / preparing workspace).
    case prompt(String)
    case waiting
    case searching(completedFileCount: Int, candidateFileCount: Int)
    case noResults
    case validationFailure(String)
    case serviceFailure(String)
}

enum WorkspaceSearchBanner: Equatable, Identifiable {
    case skipped(count: Int, detailLines: [String], omittedDetailCount: Int)
    case globalTruncation
    case perFileTruncation(pathCount: Int)

    var id: String {
        switch self {
        case let .skipped(count, _, omitted):
            "skipped-\(count)-\(omitted)"
        case .globalTruncation:
            "global-truncation"
        case let .perFileTruncation(pathCount):
            "per-file-truncation-\(pathCount)"
        }
    }
}

struct WorkspaceSearchResultRowModel: Equatable, Identifiable {
    let id: WorkspaceSearchResultRowID
    let lineNumber: Int
    let snippet: String
    let previewMatchRange: NSRange
    /// False when the result lacks retained `fileAuthority` (compatibility / non-activatable).
    let canActivate: Bool
}

struct WorkspaceSearchResultFileSectionModel: Equatable, Identifiable {
    let id: WorkspaceSearchResultFileSectionID
    let relativePath: String
    let matchCount: Int
    let isTruncated: Bool
    let canActivate: Bool
    let rows: [WorkspaceSearchResultRowModel]
}

/// Pure presentation snapshot for the Search sidebar results area.
struct WorkspaceSearchResultsPresentation: Equatable {
    var status: WorkspaceSearchStatusPresentation
    var sections: [WorkspaceSearchResultFileSectionModel]
    var banners: [WorkspaceSearchBanner]
    var showsRetry: Bool

    static let empty = WorkspaceSearchResultsPresentation(
        status: .hidden,
        sections: [],
        banners: [],
        showsRetry: false
    )
}

// MARK: - Rebuild memo inputs (exact equality, no staleness heuristics)

/// Exact inputs consumed by `WorkspaceSearchResultsPresenter.make`, compared with plain
/// `Equatable` to decide whether the memoized presentation must rebuild.
///
/// Direct comparison is deliberately chosen over a generation/phase/count key: the App event
/// path can replace a same-path `fileResults`/`skippedFiles` element in place, and a future
/// ordinary-edit/FSEvent refresh may re-emit a file with an unchanged match count — a count
/// heuristic would misread either as "no change" and serve stale rows. Unchanged inputs stay
/// cheap because the arrays inside `WorkspaceSearchState` compare by copy-on-write storage
/// identity before any element walk.
struct WorkspaceSearchResultsPresentationInputs: Equatable {
    let searchState: WorkspaceSearchState
    let queryText: String
    let canUseWorkspaceSearch: Bool
    let isWorkspaceSearchReady: Bool
}
