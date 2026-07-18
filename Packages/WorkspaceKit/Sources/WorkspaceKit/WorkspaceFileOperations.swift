import CoreFoundation
import Foundation
import ObjectiveC

public protocol WorkspaceItemRecycling: AnyObject {
    func recycle(_ requests: [WorkspaceItemRecycleRequest]) async throws -> [UUID: URL]
}

public struct WorkspaceItemRecycleRequest: @unchecked Sendable {
    public let id: UUID
    public let lexicalURL: URL
    let fileReferenceURL: NSURL

    public init(fileURL: URL) throws {
        var referenceError: Unmanaged<CFError>?
        guard let unmanagedReference = CFURLCreateFileReferenceURL(
            nil,
            fileURL as CFURL,
            &referenceError
        ) else {
            if let referenceError {
                throw referenceError.takeRetainedValue() as Error
            }
            throw CocoaError(.fileReadUnknown)
        }
        let reference = unmanagedReference.takeRetainedValue()
        guard CFURLIsFileReferenceURL(reference) else {
            throw CocoaError(.fileReadUnknown)
        }
        id = UUID()
        lexicalURL = fileURL
        fileReferenceURL = reference as NSURL
    }

    public func resolvedFileURL() throws -> URL {
        guard let resolved = fileReferenceURL.filePathURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return resolved
    }

    func retargeted(to lexicalURL: URL) -> WorkspaceItemRecycleRequest {
        WorkspaceItemRecycleRequest(
            id: id,
            lexicalURL: lexicalURL,
            fileReferenceURL: fileReferenceURL
        )
    }

    private init(id: UUID, lexicalURL: URL, fileReferenceURL: NSURL) {
        self.id = id
        self.lexicalURL = lexicalURL
        self.fileReferenceURL = fileReferenceURL
    }
}

public enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case emptyName
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "The item name cannot be empty."
        case .invalidName:
            "The item name must be one filename without path traversal."
        }
    }
}

public struct WorkspaceFileOperations: @unchecked Sendable {
    private let recycler: any WorkspaceItemRecycling

    public init(recycler: any WorkspaceItemRecycling = NSWorkspaceItemRecycler()) {
        self.recycler = recycler
    }

    func createFile(
        named name: String,
        inDirectoryRelativePath directoryRelativePath: String,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        expectingDirectory directoryExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemCreationOutcome {
        do {
            return try createFile(using: makeFileCreationPlan(
                named: name,
                inDirectoryRelativePath: directoryRelativePath,
                rootAuthority: rootAuthority,
                expectingDirectory: directoryExpectation
            ))
        } catch is WorkspaceFileOperationError {
            return .notCreated(.invalidName)
        } catch {
            return .notCreated(.destinationChanged)
        }
    }

    func createFolder(
        named name: String,
        inDirectoryRelativePath directoryRelativePath: String,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        expectingDirectory directoryExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemCreationOutcome {
        do {
            return try createFolder(using: makeFolderCreationPlan(
                named: name,
                inDirectoryRelativePath: directoryRelativePath,
                rootAuthority: rootAuthority,
                expectingDirectory: directoryExpectation
            ))
        } catch is WorkspaceFileOperationError {
            return .notCreated(.invalidName)
        } catch {
            return .notCreated(.destinationChanged)
        }
    }

    public func makeFileCreationPlan(
        named name: String,
        inDirectoryRelativePath directoryRelativePath: String,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        expectingDirectory directoryExpectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceItemCreationPlan {
        let destination = try Self.creationDestination(
            named: name,
            inDirectoryRelativePath: directoryRelativePath,
            rootAuthority: rootAuthority
        )
        let stagingLocation = try WorkspaceAnchoredItemCreator.makeStagingLocation(
            rootAuthority: rootAuthority,
            excluding: destination
        )
        return WorkspaceItemCreationPlan(
            kind: .file,
            destination: destination,
            parentExpectation: directoryExpectation,
            stagingLocation: stagingLocation
        )
    }

    public func makeFolderCreationPlan(
        named name: String,
        inDirectoryRelativePath directoryRelativePath: String,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        expectingDirectory directoryExpectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceItemCreationPlan {
        let destination = try Self.creationDestination(
            named: name,
            inDirectoryRelativePath: directoryRelativePath,
            rootAuthority: rootAuthority
        )
        let stagingLocation = try WorkspaceAnchoredItemCreator.makeStagingLocation(
            rootAuthority: rootAuthority,
            excluding: destination
        )
        return WorkspaceItemCreationPlan(
            kind: .folder,
            destination: destination,
            parentExpectation: directoryExpectation,
            stagingLocation: stagingLocation
        )
    }

    public func createFile(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void = { _ in }
    ) -> WorkspaceItemCreationOutcome {
        WorkspaceAnchoredItemCreator.createFile(
            using: plan,
            recordingCreatedArtifact: recordingCreatedArtifact
        )
    }

    public func createFolder(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void = { _ in }
    ) -> WorkspaceItemCreationOutcome {
        WorkspaceAnchoredItemCreator.createDirectory(
            using: plan,
            recordingCreatedArtifact: recordingCreatedArtifact
        )
    }

    public func trash(
        _ source: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        stagingPlan: WorkspaceItemTrashStagingPlan
    ) async -> WorkspaceItemTrashOutcome {
        await WorkspaceAnchoredItemTrasher.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            stagingPlan: stagingPlan,
            recycler: recycler
        )
    }

    public func makeTrashStagingPlan(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) throws -> WorkspaceItemTrashStagingPlan {
        try WorkspaceAnchoredItemTrasher.makeStagingPlan(
            rootAuthority: rootAuthority
        )
    }

    public func rename(
        _ source: WorkspaceFileSystemLocation,
        to newName: String,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemMutationOutcome<Void> {
        rename(
            source,
            to: newName,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            preparingCommit: { _ in () }
        )
    }

    public func rename<Prepared>(
        _ source: WorkspaceFileSystemLocation,
        to newName: String,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        let validatedName: String
        do {
            validatedName = try Self.validatedSingleComponentName(newName)
        } catch {
            return .notMoved(.invalidName)
        }
        guard let destination = source.sibling(named: validatedName) else {
            return .notMoved(.invalidName)
        }
        return WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: sourceParentExpectation,
            preparingCommit: preparingCommit
        )
    }

    public func move(
        _ source: WorkspaceFileSystemLocation,
        to destination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemMutationOutcome<Void> {
        move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: { _ in () }
        )
    }

    public func move<Prepared>(
        _ source: WorkspaceFileSystemLocation,
        to destination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        WorkspaceAnchoredItemMutator.relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: preparingCommit
        )
    }

    private static func validatedSingleComponentName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }
        guard name != ".",
              name != "..",
              !name.utf8.contains(0),
              !name.utf8.contains(0x2F)
        else {
            throw WorkspaceFileOperationError.invalidName
        }
        return name
    }

    private static func creationDestination(
        named name: String,
        inDirectoryRelativePath directoryRelativePath: String,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) throws -> WorkspaceFileSystemLocation {
        let name = try validatedSingleComponentName(name)
        let directory: String
        if directoryRelativePath.isEmpty {
            directory = ""
        } else {
            let normalized = try WorkspaceRootContainment.normalizedRelativePath(
                directoryRelativePath
            )
            guard normalized.utf8.elementsEqual(directoryRelativePath.utf8) else {
                throw WorkspaceCreationDestinationError.invalidDirectoryPath
            }
            directory = normalized
        }
        return try rootAuthority.location(
            relativePath: directory.isEmpty ? name : "\(directory)/\(name)"
        )
    }
}

private enum WorkspaceCreationDestinationError: Error {
    case invalidDirectoryPath
}

public final class NSWorkspaceItemRecycler: WorkspaceItemRecycling, @unchecked Sendable {
    public init() {}

    public func recycle(
        _ requests: [WorkspaceItemRecycleRequest]
    ) async throws -> [UUID: URL] {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager()
            var results: [UUID: URL] = [:]
            for request in requests {
                results[request.id] = try Self.trash(
                    request.fileReferenceURL,
                    using: fileManager
                )
            }
            return results
        }.value
    }

    private static func trash(
        _ fileReferenceURL: NSURL,
        using fileManager: FileManager
    ) throws -> URL {
        guard fileReferenceURL.isFileReferenceURL() else {
            throw CocoaError(.fileReadUnknown)
        }
        let selector = NSSelectorFromString("trashItemAtURL:resultingItemURL:error:")
        guard fileManager.responds(to: selector) else {
            throw CocoaError(.featureUnsupported)
        }
        typealias TrashItemImplementation = @convention(c) (
            AnyObject,
            Selector,
            NSURL,
            AutoreleasingUnsafeMutablePointer<NSURL?>?,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool
        let implementation = unsafeBitCast(
            fileManager.method(for: selector),
            to: TrashItemImplementation.self
        )
        var resultingURL: NSURL?
        var error: NSError?
        guard implementation(
            fileManager,
            selector,
            fileReferenceURL,
            &resultingURL,
            &error
        ) else {
            throw error ?? CocoaError(.fileWriteUnknown)
        }
        guard let resultingURL else {
            throw CocoaError(.fileWriteUnknown)
        }
        return resultingURL as URL
    }
}
