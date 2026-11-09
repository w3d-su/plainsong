import Foundation
import WorkspaceKit

/// Result sections for the search sidebar, rebuilt only where the file results changed.
///
/// A section depends only on its file result and the query generation. The streamed search
/// state also carries progress counts that change on every completed file, and rebuilding
/// every row of every file for each of those updates made a large search quadratic. This
/// cache keeps the sections of the unchanged leading file results (a stream appends) and
/// builds the rest; a new generation rebuilds everything. Results are compared with plain
/// `Equatable`, so an in-place rewrite of an earlier file is still picked up. Owned by one
/// sidebar view and used only from its updates.
final class WorkspaceSearchResultSectionsCache {
    private var fileResults: [WorkspaceSearchFileResult] = []
    private var queryGeneration: UInt64?
    private var cachedSections: [WorkspaceSearchResultFileSectionModel] = []
    /// Sections built since creation (tests).
    private(set) var builtSectionCount = 0

    func sections(
        for fileResults: [WorkspaceSearchFileResult],
        queryGeneration: UInt64
    ) -> [WorkspaceSearchResultFileSectionModel] {
        var reusable = 0
        if self.queryGeneration == queryGeneration {
            let limit = min(self.fileResults.count, fileResults.count)
            while reusable < limit, self.fileResults[reusable] == fileResults[reusable] {
                reusable += 1
            }
            if reusable == fileResults.count, reusable == self.fileResults.count {
                return cachedSections
            }
        }

        var sections = Array(cachedSections.prefix(reusable))
        sections.reserveCapacity(fileResults.count)
        for fileResult in fileResults[reusable...] {
            sections.append(WorkspaceSearchResultsPresenter.makeSection(
                for: fileResult,
                queryGeneration: queryGeneration
            ))
        }
        builtSectionCount += fileResults.count - reusable

        self.fileResults = fileResults
        self.queryGeneration = queryGeneration
        cachedSections = sections
        return sections
    }
}
