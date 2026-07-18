import Foundation
import WorkspaceKit

@MainActor
extension AppState {
    enum WorkspaceCreationKind {
        case file
        case folder
    }

    struct WorkspaceCreationDirectory {
        let relativePath: String
        let expectation: WorkspaceItemMutationExpectation
    }

    func exactRelativePath(
        _ candidate: String,
        isAffectedBy source: String,
        sourceIsDirectory: Bool
    ) -> Bool {
        workspaceMutationRelativePathIsAffected(
            candidate,
            source: source,
            sourceIsDirectory: sourceIsDirectory
        )
    }

    func relocatedRelativePath(
        _ candidate: String,
        from source: String,
        to destination: String,
        sourceIsDirectory: Bool
    ) -> String {
        guard sourceIsDirectory else { return destination }
        let candidateComponents = exactRelativePathComponents(candidate)
        let sourceComponents = exactRelativePathComponents(source)
        let destinationComponents = exactRelativePathComponents(destination)
        return (destinationComponents + candidateComponents.dropFirst(sourceComponents.count))
            .joined(separator: "/")
    }

    func exactRelativePathComponents(_ relativePath: String) -> [String] {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func exactPathBytes(_ url: URL) -> [UInt8] {
        Array(url.path(percentEncoded: false).utf8)
    }

    func exactURLValue<Value>(in values: [URL: Value], at url: URL) -> Value? {
        values.first { exactFileURLSpellingMatches($0.key, url) }?.value
    }

    func removeExactURLValue(in values: inout [URL: some Any], at url: URL) {
        guard let key = values.keys.first(where: {
            exactFileURLSpellingMatches($0, url)
        }) else {
            return
        }
        values[key] = nil
    }

    func workspaceMutationParentExpectation(
        for relativePath: String,
        tree: WorkspaceFileTree,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> WorkspaceItemMutationExpectation? {
        let components = exactRelativePathComponents(relativePath)
        guard !components.isEmpty else { return nil }
        let parentPath = components.dropLast().joined(separator: "/")
        guard !parentPath.isEmpty else {
            return rootAuthority.directoryMutationExpectation
        }
        guard let parentNode = firstNode(in: tree.root, relativePath: parentPath),
              parentNode.isDirectory
        else {
            return nil
        }
        return parentNode.mutationExpectation
    }

    func workspaceCreationDirectory(
        directoryID: WorkspaceFileNode.ID?,
        tree: WorkspaceFileTree,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) throws -> WorkspaceCreationDirectory {
        guard let directoryID else {
            return WorkspaceCreationDirectory(
                relativePath: "",
                expectation: rootAuthority.directoryMutationExpectation
            )
        }
        guard let node = tree.node(id: directoryID),
              node.isDirectory
        else {
            throw WorkspaceMutationError.unavailableWorkspaceDirectory
        }
        if node.relativePath.isEmpty {
            return WorkspaceCreationDirectory(
                relativePath: "",
                expectation: rootAuthority.directoryMutationExpectation
            )
        }
        guard let expectation = node.mutationExpectation else {
            throw WorkspaceMutationError.unavailableWorkspaceDirectory
        }
        return WorkspaceCreationDirectory(
            relativePath: node.relativePath,
            expectation: expectation
        )
    }
}

func workspaceMutationRelativePathIsAffected(
    _ candidate: String,
    source: String,
    sourceIsDirectory: Bool
) -> Bool {
    let candidateComponents = candidate
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    let sourceComponents = source
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
    guard sourceIsDirectory else {
        return candidateComponents.count == sourceComponents.count &&
            zip(candidateComponents, sourceComponents).allSatisfy {
                $0.utf8.elementsEqual($1.utf8)
            }
    }
    guard candidateComponents.count >= sourceComponents.count else { return false }
    return zip(candidateComponents, sourceComponents).allSatisfy {
        $0.utf8.elementsEqual($1.utf8)
    }
}

enum WorkspaceMutationError: LocalizedError {
    case invalidName
    case workspaceRootIsImmutable
    case itemOutsideWorkspace(URL)
    case staleWorkspaceSnapshot(URL)
    case unprovenSessionAuthority(URL)
    case indeterminateSession(URL)
    case unsavedChanges(URL)
    case sessionDestinationConflict(URL)
    case operationAlreadyInProgress
    case imageInsertionInProgress
    case unavailableWorkspaceDirectory
    case trashStagingCleanupRequired(URL)
    case unexpectedDestination(URL)
    case operationFailed(WorkspaceItemMutationFailure, URL)
    case indeterminateOperation(URL, WorkspaceItemMutationFailure)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "The item name must be one filename without path traversal."
        case .workspaceRootIsImmutable:
            "The workspace root cannot be renamed, moved, or trashed from the sidebar."
        case let .itemOutsideWorkspace(url):
            "\(url.lastPathComponent) is outside the active workspace."
        case let .staleWorkspaceSnapshot(url):
            "\(url.lastPathComponent) changed after the workspace snapshot. Refresh and try again."
        case let .unprovenSessionAuthority(url):
            "The editor can no longer prove ownership of \(url.lastPathComponent)."
        case let .indeterminateSession(url):
            "\(url.lastPathComponent) already requires filesystem reconciliation."
        case let .unsavedChanges(url):
            "Save or discard changes in \(url.lastPathComponent) before moving it to Trash."
        case let .sessionDestinationConflict(url):
            "An editor session or pending editor state already owns \(url.lastPathComponent)."
        case .operationAlreadyInProgress:
            "Another workspace filesystem operation is still in progress."
        case .imageInsertionInProgress:
            "Wait for the current image insertion to finish before moving workspace items."
        case .unavailableWorkspaceDirectory:
            "The selected workspace folder is no longer available. Refresh and try again."
        case let .trashStagingCleanupRequired(url):
            "The item reached Trash, but Plainsong could not remove staging folder \(url.lastPathComponent)."
        case let .unexpectedDestination(url):
            "The file operation completed at an unexpected location: \(url.path)."
        case let .operationFailed(failure, url):
            "Could not move \(url.lastPathComponent): \(failure)."
        case let .indeterminateOperation(url, failure):
            "The final location of \(url.lastPathComponent) could not be proven (\(failure))."
        }
    }
}
