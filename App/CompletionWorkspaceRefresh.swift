import Foundation
import MarkdownCore
import WorkspaceKit

/// Workspace-derived completion metadata for one installed capture and current file.
/// `base == nil` records that the capture could not supply paths (an entry escaped the root).
struct CompletionWorkspaceBaseCache {
    let captureGeneration: UInt64
    let currentFileLocation: WorkspaceFileSystemLocation
    let base: CompletionWorkspaceBase?
}

enum CompletionWorkspaceBaseLookup: Sendable {
    case cached(CompletionWorkspaceBase?)
    case uncached
}

enum ComputedCompletionWorkspaceBase: Sendable {
    case computed(CompletionWorkspaceBase?)
    case notComputed
}

/// Off-main half of `AppState.scheduleCompletionWorkspaceRefresh`.
enum CompletionWorkspaceRefresh {
    /// Builds completion metadata, reading the workspace only when `baseLookup` has no
    /// base for this capture and file. The second value is the base to cache, if one was read.
    /// `currentFileLocation` carries the root authority; `nil` means no workspace capture
    /// (or a current file outside it).
    static func workspace(
        currentFileLocation: WorkspaceFileSystemLocation?,
        snapshot: WorkspaceFileSnapshot?,
        fileURL: URL?,
        text: String,
        baseLookup: CompletionWorkspaceBaseLookup
    ) -> (CompletionWorkspace, ComputedCompletionWorkspaceBase) {
        let provider = CompletionWorkspaceProvider()
        guard let currentFileLocation, let snapshot else {
            let workspace = (try? provider.workspace(
                rootURL: nil,
                currentFileURL: fileURL,
                currentText: text,
                tree: nil
            )) ?? CompletionWorkspace(
                currentFilePath: fileURL?.lastPathComponent,
                currentFileHeadingAnchors: []
            )
            return (workspace, .notComputed)
        }

        let base: CompletionWorkspaceBase?
        let computed: ComputedCompletionWorkspaceBase
        switch baseLookup {
        case let .cached(cachedBase):
            base = cachedBase
            computed = .notComputed
        case .uncached:
            base = try? provider.workspaceBase(
                rootAuthority: currentFileLocation.rootAuthority,
                currentFileLocation: currentFileLocation,
                snapshot: snapshot
            )
            computed = .computed(base)
        }
        guard let base else {
            // Same fallback as a failed full build: the file name only.
            return (
                CompletionWorkspace(
                    currentFilePath: currentFileLocation.fileURL.lastPathComponent,
                    currentFileHeadingAnchors: []
                ),
                computed
            )
        }
        return (provider.workspace(base: base, currentText: text), computed)
    }
}

extension CompletionWorkspace {
    /// `==` compares strings by canonical equivalence; a rename between NFC and NFD
    /// spellings must still republish the path the completion inserts.
    func isLiterallyIdentical(to other: CompletionWorkspace) -> Bool {
        func same(_ first: [String], _ second: [String]) -> Bool {
            first.elementsEqual(second) { ExactSourceText.matches($0, $1) }
        }
        let currentFilePathMatches = switch (currentFilePath, other.currentFilePath) {
        case (nil, nil): true
        case let (first?, second?): ExactSourceText.matches(first, second)
        default: false
        }
        return currentFilePathMatches
            && same(markdownFilePaths, other.markdownFilePaths)
            && same(imageFilePaths, other.imageFilePaths)
            && same(currentFileHeadingAnchors, other.currentFileHeadingAnchors)
            && same(frontmatterKeys, other.frontmatterKeys)
            && same(componentNames, other.componentNames)
            && same(recentlyUsedCompletionIDs, other.recentlyUsedCompletionIDs)
    }
}
