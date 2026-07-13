import Foundation
import MarkdownCore

struct WorkspaceSearchCandidatePlan {
    let items: [WorkspaceSearchCandidatePlanItem]
    let candidateFileCount: Int
    let ignoredFileCount: Int
}

enum WorkspaceSearchCandidatePlanItem {
    case ignored(sortKey: String)
    case skipped(sortKey: String, skippedFile: WorkspaceSearchSkippedFile)
    case candidate(sortKey: String, candidate: WorkspaceSearchCandidate)

    var sortKey: String {
        switch self {
        case let .ignored(sortKey), let .skipped(sortKey, _), let .candidate(sortKey, _):
            sortKey
        }
    }
}

struct WorkspaceSearchCandidate {
    let relativePath: String
    let overlay: WorkspaceSearchOverlay?
}

enum WorkspaceSearchCandidatePlanner {
    static func makePlan(
        request: WorkspaceSearchRequest,
        reader: any WorkspaceSearchFileReading
    ) async throws -> WorkspaceSearchCandidatePlan {
        let entries = request.snapshot.entries
            .filter(\.kind.isEditableMarkdown)
            .sorted(by: compare)
        var invalidItems: [WorkspaceSearchCandidatePlanItem] = []
        var validEntries: [WorkspaceSearchCandidate] = []
        var hardIgnoredItems: [WorkspaceSearchCandidatePlanItem] = []
        var seenCanonicalCandidatePaths: Set<String> = []

        for entry in entries {
            switch try classify(entry, request: request) {
            case let .invalid(item):
                invalidItems.append(item)
            case let .hardIgnored(item):
                hardIgnoredItems.append(item)
            case let .candidate(candidate):
                if seenCanonicalCandidatePaths.insert(candidate.relativePath).inserted {
                    validEntries.append(candidate)
                }
            }
        }

        let ignorePolicy = try await WorkspaceSearchIgnorePolicy.load(
            rootAuthority: request.rootAuthority,
            candidatePaths: validEntries.map(\.relativePath),
            limits: request.limits,
            reader: reader
        )
        try Task.checkCancellation()

        var items = invalidItems
        items.append(contentsOf: hardIgnoredItems)
        for candidate in validEntries {
            if ignorePolicy.isIgnored(relativePath: candidate.relativePath) {
                items.append(.ignored(sortKey: candidate.relativePath))
            } else {
                items.append(.candidate(sortKey: candidate.relativePath, candidate: candidate))
            }
        }
        items.sort { first, second in
            first.sortKey == second.sortKey ? planItemRank(first) < planItemRank(second) : first.sortKey < second
                .sortKey
        }

        return WorkspaceSearchCandidatePlan(
            items: items,
            candidateFileCount: items.count,
            ignoredFileCount: items.reduce(into: 0) { count, item in
                if case .ignored = item {
                    count += 1
                }
            }
        )
    }

    private static func classify(
        _ entry: WorkspaceFileSnapshot.Entry,
        request: WorkspaceSearchRequest
    ) throws -> WorkspaceSearchCandidateClassification {
        try Task.checkCancellation()
        let sortKey = entry.relativePath
        let relativePath: String
        do {
            relativePath = try WorkspaceRootContainment.normalizedRelativePath(entry.relativePath)
        } catch {
            return .invalid(.skipped(
                sortKey: sortKey,
                skippedFile: WorkspaceSearchSkippedFile(
                    relativePath: entry.relativePath,
                    reason: skipReason(for: error)
                )
            ))
        }

        let canonicalLocation: WorkspaceFileSystemLocation
        do {
            canonicalLocation = try request.rootAuthority.canonicalizedLocation(
                relativePath: relativePath
            )
        } catch WorkspaceAnchoredFileSystemError.missing {
            // A stale snapshot entry remains a candidate so the production anchored read
            // owns the typed `disappeared` decision. A dangling alias is still rejected by
            // that no-follow read rather than being followed through another namespace.
            canonicalLocation = try request.rootAuthority.location(relativePath: relativePath)
        } catch {
            return .invalid(.skipped(
                sortKey: relativePath,
                skippedFile: WorkspaceSearchSkippedFile(
                    relativePath: relativePath,
                    reason: skipReason(for: error)
                )
            ))
        }

        let canonicalRelativePath = canonicalLocation.relativePath
        guard FileKind(url: canonicalLocation.fileURL) != nil else {
            return .invalid(.skipped(
                sortKey: relativePath,
                skippedFile: WorkspaceSearchSkippedFile(
                    relativePath: relativePath,
                    reason: .unsupportedPhysicalFileKind
                )
            ))
        }

        if isAlwaysIgnored(canonicalRelativePath) {
            return .hardIgnored(.ignored(sortKey: canonicalRelativePath))
        }
        return .candidate(WorkspaceSearchCandidate(
            relativePath: canonicalRelativePath,
            overlay: request.dirtyOverlays[canonicalRelativePath]
        ))
    }

    private static func compare(
        _ first: WorkspaceFileSnapshot.Entry,
        _ second: WorkspaceFileSnapshot.Entry
    ) -> Bool {
        if first.relativePath != second.relativePath {
            return first.relativePath < second.relativePath
        }
        return (first.identity ?? "") < (second.identity ?? "")
    }

    private static func planItemRank(_ item: WorkspaceSearchCandidatePlanItem) -> Int {
        switch item {
        case .candidate:
            0
        case .skipped:
            1
        case .ignored:
            2
        }
    }

    private static func skipReason(for error: Error) -> WorkspaceSearchSkipReason {
        switch error {
        case WorkspaceRootContainmentError.emptyRelativePath:
            .emptyPath
        case WorkspaceRootContainmentError.absolutePath:
            .absolutePath
        case WorkspaceRootContainmentError.traversal:
            .pathTraversal
        case WorkspaceRootContainmentError.symlinkEscape:
            .symlinkEscape
        case WorkspaceRootContainmentError.fileOutsideRoot:
            .symlinkEscape
        case WorkspaceAnchoredFileSystemError.symbolicLink,
             WorkspaceAnchoredFileSystemError.changedIdentity,
             WorkspaceAnchoredFileSystemError.namespaceChanged:
            .symlinkEscape
        case WorkspaceAnchoredFileSystemError.notRegularFile:
            .unsupportedPhysicalFileKind
        default:
            .pathTraversal
        }
    }

    private static func isAlwaysIgnored(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return components.contains { component in
            let lowercased = component.lowercased()
            return component.hasPrefix(".")
                || excludedDirectoryNames.contains(lowercased)
                || packageExtensions.contains((component as NSString).pathExtension.lowercased())
        }
    }

    private static let excludedDirectoryNames: Set<String> = [
        ".git",
        "node_modules",
        ".build",
        ".next",
        ".astro",
        "deriveddata",
        "dist",
        "build",
    ]

    private static let packageExtensions: Set<String> = [
        "app",
        "bundle",
        "framework",
        "kext",
        "mdimporter",
        "pkg",
        "plugin",
        "playground",
        "xcodeproj",
        "xcworkspace",
    ]
}

private enum WorkspaceSearchCandidateClassification {
    case invalid(WorkspaceSearchCandidatePlanItem)
    case hardIgnored(WorkspaceSearchCandidatePlanItem)
    case candidate(WorkspaceSearchCandidate)
}
