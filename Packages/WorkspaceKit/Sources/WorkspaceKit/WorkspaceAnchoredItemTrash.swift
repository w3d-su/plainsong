import Darwin
import Foundation

public enum WorkspaceTrashStagingCleanupState: Sendable, Equatable {
    case notCreated
    case removed
    case removalIndeterminate(WorkspaceFileSystemLocation)
}

/// A caller-created write-ahead intent for the exact hidden root entry used to stage one
/// Trash mutation. Callers can persist this value's location before any namespace change.
public struct WorkspaceItemTrashStagingPlan: Sendable, Hashable {
    public let stagingLocation: WorkspaceFileSystemLocation
    public let rootParentExpectation: WorkspaceItemMutationExpectation
}

public struct WorkspaceNotTrashedItem: Sendable, Equatable {
    public let source: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation
    public let reason: WorkspaceItemMutationFailure
    public let stagingCleanupState: WorkspaceTrashStagingCleanupState

    public init(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure,
        stagingCleanupState: WorkspaceTrashStagingCleanupState
    ) {
        self.source = source
        self.expectation = expectation
        self.reason = reason
        self.stagingCleanupState = stagingCleanupState
    }
}

public struct WorkspaceTrashedItem: Sendable, Equatable {
    public let source: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation
    public let trashURL: URL
    public let stagingCleanupState: WorkspaceTrashStagingCleanupState

    public init(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        trashURL: URL,
        stagingCleanupState: WorkspaceTrashStagingCleanupState
    ) {
        self.source = source
        self.expectation = expectation
        self.trashURL = trashURL
        self.stagingCleanupState = stagingCleanupState
    }
}

public struct WorkspaceIndeterminateItemTrash: Sendable, Equatable {
    public let source: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation
    public let reason: WorkspaceItemMutationFailure
    public let recoveryLocation: WorkspaceFileSystemLocation?
    public let reportedTrashURL: URL?
    public let stagingCleanupState: WorkspaceTrashStagingCleanupState
    public let actualStagedExpectation: WorkspaceItemMutationExpectation?

    public init(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure,
        recoveryLocation: WorkspaceFileSystemLocation?,
        reportedTrashURL: URL?,
        stagingCleanupState: WorkspaceTrashStagingCleanupState,
        actualStagedExpectation: WorkspaceItemMutationExpectation? = nil
    ) {
        self.source = source
        self.expectation = expectation
        self.reason = reason
        self.recoveryLocation = recoveryLocation
        self.reportedTrashURL = reportedTrashURL
        self.stagingCleanupState = stagingCleanupState
        self.actualStagedExpectation = actualStagedExpectation
    }
}

public enum WorkspaceItemTrashOutcome: Sendable, Equatable {
    case notTrashed(WorkspaceNotTrashedItem)
    case trashed(WorkspaceTrashedItem)
    case trashStateIndeterminate(WorkspaceIndeterminateItemTrash)
}

public enum WorkspaceAnchoredItemTrasher {
    public static func makeStagingPlan(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) throws -> WorkspaceItemTrashStagingPlan {
        let rootParentExpectation = rootAuthority.directoryMutationExpectation
        for _ in 0 ..< 16 {
            let name = ".plainsong-trash-\(UUID().uuidString.lowercased())"
            let stagingLocation = try rootAuthority.location(relativePath: name)
            guard try WorkspaceNoFollowItemInspector.inspectParent(
                of: stagingLocation
            ) == rootParentExpectation else {
                throw WorkspaceItemMutationFailure.destinationChanged
            }
            do {
                _ = try WorkspaceNoFollowItemInspector.inspect(at: stagingLocation)
            } catch WorkspaceAnchoredFileSystemError.missing {
                return WorkspaceItemTrashStagingPlan(
                    stagingLocation: stagingLocation,
                    rootParentExpectation: rootParentExpectation
                )
            }
        }
        throw WorkspaceItemMutationFailure.destinationExists
    }

    public static func trash(
        _ source: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        stagingPlan: WorkspaceItemTrashStagingPlan,
        recycler: any WorkspaceItemRecycling
    ) async -> WorkspaceItemTrashOutcome {
        let securityScope = SecurityScopedAccess.startAccessing(source.securityScopedURL)
        defer { securityScope.stop() }

        let recycleRequest: WorkspaceItemRecycleRequest
        do {
            recycleRequest = try prepareRecycleRequest(
                source: source,
                expectation: expectation,
                stagingPlan: stagingPlan
            )
        } catch {
            return notTrashed(
                source: source,
                expectation: expectation,
                reason: failure(for: error),
                cleanupState: .notCreated
            )
        }

        let stagedLocation = stagingPlan.stagingLocation

        let stageOutcome = WorkspaceAnchoredItemMutator.relocate(
            source,
            to: stagedLocation,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: stagingPlan.rootParentExpectation,
            preparingCommit: { relocation in
                guard try WorkspaceNoFollowItemInspector.inspect(at: relocation.destination) == expectation else {
                    throw WorkspaceItemMutationFailure.sourceChanged
                }
            }
        )
        switch stageOutcome {
        case let .notMoved(reason):
            return notTrashed(
                source: source,
                expectation: expectation,
                reason: reason,
                cleanupState: .notCreated
            )
        case let .movedButIndeterminate(indeterminate):
            return reconcileIndeterminateStagingMove(
                source: source,
                stagedLocation: stagedLocation,
                expectation: expectation,
                sourceParentExpectation: sourceParentExpectation,
                reason: indeterminate.reason,
                actualStagedExpectation: indeterminate.actualMovedExpectation
            )
        case .movedAndDurable:
            break
        }

        let stagedRecycleRequest = recycleRequest.retargeted(to: stagedLocation.fileURL)
        let mapping: [UUID: URL]
        do {
            mapping = try await recycler.recycle([stagedRecycleRequest])
        } catch {
            return reconcileFailedRecyclerHandoff(
                source: source,
                stagedLocation: stagedLocation,
                expectation: expectation,
                reason: .recyclerFailed
            )
        }

        guard let reportedTrashURL = mapping[stagedRecycleRequest.id] else {
            return reconcileUnprovenRecyclerResult(
                source: source,
                stagedLocation: stagedLocation,
                expectation: expectation,
                reportedTrashURL: nil
            )
        }
        guard noFollowExpectation(at: reportedTrashURL) == expectation,
              retainedState(at: stagedLocation, expecting: expectation) == .missing,
              retainedState(at: source, expecting: expectation) == .missing
        else {
            return reconcileUnprovenRecyclerResult(
                source: source,
                stagedLocation: stagedLocation,
                expectation: expectation,
                reportedTrashURL: reportedTrashURL
            )
        }

        return .trashed(.init(
            source: source,
            expectation: expectation,
            trashURL: reportedTrashURL,
            stagingCleanupState: .removed
        ))
    }
}

private extension WorkspaceAnchoredItemTrasher {
    static func prepareRecycleRequest(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        stagingPlan: WorkspaceItemTrashStagingPlan
    ) throws -> WorkspaceItemRecycleRequest {
        try validate(
            stagingPlan: stagingPlan,
            for: source
        )
        guard retainedState(at: source, expecting: expectation) == .expected else {
            throw WorkspaceItemMutationFailure.sourceChanged
        }
        let request = try WorkspaceItemRecycleRequest(fileURL: source.fileURL)
        guard try noFollowExpectation(at: request.resolvedFileURL()) == expectation,
              retainedState(at: source, expecting: expectation) == .expected
        else {
            throw WorkspaceItemMutationFailure.sourceChanged
        }
        return request
    }

    static func notTrashed(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure,
        cleanupState: WorkspaceTrashStagingCleanupState
    ) -> WorkspaceItemTrashOutcome {
        .notTrashed(.init(
            source: source,
            expectation: expectation,
            reason: reason,
            stagingCleanupState: cleanupState
        ))
    }

    static func validate(
        stagingPlan: WorkspaceItemTrashStagingPlan,
        for source: WorkspaceFileSystemLocation
    ) throws {
        let stagingLocation = stagingPlan.stagingLocation
        guard stagingLocation.rootAuthority == source.rootAuthority else {
            throw WorkspaceItemMutationFailure.differentRootAuthority
        }
        guard stagingPlan.rootParentExpectation
            == stagingLocation.rootAuthority.directoryMutationExpectation
        else {
            throw WorkspaceItemMutationFailure.destinationChanged
        }
        let prefix = ".plainsong-trash-"
        let relativePath = stagingLocation.relativePath
        guard !relativePath.utf8.contains(0x2F),
              relativePath.hasPrefix(prefix),
              UUID(uuidString: String(relativePath.dropFirst(prefix.count))) != nil
        else {
            throw WorkspaceItemMutationFailure.destinationChanged
        }
        guard try WorkspaceNoFollowItemInspector.inspectParent(of: stagingLocation)
            == stagingPlan.rootParentExpectation
        else {
            throw WorkspaceItemMutationFailure.destinationChanged
        }
    }

    static func reconcileFailedRecyclerHandoff(
        source: WorkspaceFileSystemLocation,
        stagedLocation: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure
    ) -> WorkspaceItemTrashOutcome {
        let sourceState = retainedState(at: source, expecting: expectation)
        let stagedState = retainedState(at: stagedLocation, expecting: expectation)
        if sourceState == .expected, stagedState == .missing {
            return notTrashed(
                source: source,
                expectation: expectation,
                reason: reason,
                cleanupState: .removed
            )
        }
        let recoveryLocation = provenLocation(
            expectation: expectation,
            candidates: [source, stagedLocation]
        )
        return .trashStateIndeterminate(.init(
            source: source,
            expectation: expectation,
            reason: reason,
            recoveryLocation: recoveryLocation,
            reportedTrashURL: nil,
            stagingCleanupState: indeterminateCleanupState(
                stagedLocation: stagedLocation,
                recoveryLocation: recoveryLocation,
                expectation: expectation
            ),
            actualStagedExpectation: unexpectedExpectation(
                at: stagedLocation,
                expected: expectation
            )
        ))
    }

    static func reconcileUnprovenRecyclerResult(
        source: WorkspaceFileSystemLocation,
        stagedLocation: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        reportedTrashURL: URL?
    ) -> WorkspaceItemTrashOutcome {
        if retainedState(at: stagedLocation, expecting: expectation) == .expected {
            return reconcileFailedRecyclerHandoff(
                source: source,
                stagedLocation: stagedLocation,
                expectation: expectation,
                reason: .sourceChanged
            )
        }
        let recoveryLocation = provenLocation(
            expectation: expectation,
            candidates: [source, stagedLocation]
        )
        return .trashStateIndeterminate(.init(
            source: source,
            expectation: expectation,
            reason: .sourceChanged,
            recoveryLocation: recoveryLocation,
            reportedTrashURL: reportedTrashURL,
            stagingCleanupState: indeterminateCleanupState(
                stagedLocation: stagedLocation,
                recoveryLocation: recoveryLocation,
                expectation: expectation
            ),
            actualStagedExpectation: unexpectedExpectation(
                at: stagedLocation,
                expected: expectation
            )
        ))
    }

    static func provenLocation(
        expectation: WorkspaceItemMutationExpectation,
        candidates: [WorkspaceFileSystemLocation]
    ) -> WorkspaceFileSystemLocation? {
        candidates.first { candidate in
            retainedState(at: candidate, expecting: expectation) == .expected
        }
    }

    static func retainedState(
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> RetainedExpectationState {
        do {
            return try WorkspaceNoFollowItemInspector.inspect(at: location) == expectation
                ? .expected
                : .mismatch
        } catch WorkspaceAnchoredFileSystemError.missing {
            return .missing
        } catch {
            return .mismatch
        }
    }

    static func reconcileIndeterminateStagingMove(
        source: WorkspaceFileSystemLocation,
        stagedLocation: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure,
        actualStagedExpectation: WorkspaceItemMutationExpectation?
    ) -> WorkspaceItemTrashOutcome {
        let sourceState = retainedState(at: source, expecting: expectation)
        let stagedState = retainedState(at: stagedLocation, expecting: expectation)
        if sourceState == .expected,
           parentExpectation(at: source) == sourceParentExpectation,
           stagedState == .missing
        {
            return notTrashed(
                source: source,
                expectation: expectation,
                reason: reason,
                cleanupState: .removed
            )
        }
        let recoveryLocation = provenLocation(
            expectation: expectation,
            candidates: [source, stagedLocation]
        )
        return .trashStateIndeterminate(.init(
            source: source,
            expectation: expectation,
            reason: reason,
            recoveryLocation: recoveryLocation,
            reportedTrashURL: nil,
            stagingCleanupState: indeterminateCleanupState(
                stagedLocation: stagedLocation,
                recoveryLocation: recoveryLocation,
                expectation: expectation
            ),
            actualStagedExpectation: actualStagedExpectation
        ))
    }

    static func indeterminateCleanupState(
        stagedLocation: WorkspaceFileSystemLocation,
        recoveryLocation: WorkspaceFileSystemLocation?,
        expectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceTrashStagingCleanupState {
        if recoveryLocation == stagedLocation || retainedState(
            at: stagedLocation,
            expecting: expectation
        ) != .missing {
            return .removalIndeterminate(stagedLocation)
        }
        return .removed
    }

    static func noFollowExpectation(at url: URL) -> WorkspaceItemMutationExpectation? {
        guard url.isFileURL, !url.path(percentEncoded: false).utf8.contains(0) else { return nil }
        var status = stat()
        guard Darwin.lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return WorkspaceItemMutationExpectation(
            identity: .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)),
            kind: WorkspaceFileSystemItemKind(mode: status.st_mode)
        )
    }

    static func unexpectedExpectation(
        at location: WorkspaceFileSystemLocation,
        expected: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemMutationExpectation? {
        guard let actual = try? WorkspaceNoFollowItemInspector.inspect(at: location),
              actual != expected
        else {
            return nil
        }
        return actual
    }

    static func parentExpectation(
        at location: WorkspaceFileSystemLocation
    ) -> WorkspaceItemMutationExpectation? {
        try? WorkspaceNoFollowItemInspector.inspectParent(of: location)
    }

    static func failure(for error: Error) -> WorkspaceItemMutationFailure {
        if let failure = error as? WorkspaceItemMutationFailure { return failure }
        guard let anchored = error as? WorkspaceAnchoredFileSystemError else { return .unreadable }
        return switch anchored {
        case .missing:
            .sourceMissing
        case .changedIdentity:
            .sourceChanged
        case .namespaceChanged, .symbolicLink, .notRegularFile, .unstable:
            .namespaceChanged
        case .durabilityFailed:
            .durabilityFailed
        case .cancelled:
            .cancelled
        case .unreadable, .changedContent, .cleanupFailed:
            .unreadable
        }
    }

    enum RetainedExpectationState: Equatable {
        case expected
        case missing
        case mismatch
    }
}
