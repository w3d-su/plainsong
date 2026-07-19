import Foundation
import WorkspaceKit

// swiftlint:disable:next type_body_length
struct WorkspaceMutationOperationRecoveryRecord: Codable, Equatable, Identifiable {
    struct Expectation: Codable, Equatable {
        enum Kind: String, Codable {
            case directory
            case other
            case regularFile
            case symbolicLink
        }

        let device: UInt64
        let inode: UInt64
        let kind: Kind

        init(device: UInt64, inode: UInt64, kind: Kind) {
            self.device = device
            self.inode = inode
            self.kind = kind
        }

        init(_ expectation: WorkspaceItemMutationExpectation) {
            device = expectation.identity.device
            inode = expectation.identity.inode
            kind = switch expectation.kind {
            case .directory:
                .directory
            case .other:
                .other
            case .regularFile:
                .regularFile
            case .symbolicLink:
                .symbolicLink
            }
        }

        var runtimeValue: WorkspaceItemMutationExpectation {
            let runtimeKind: WorkspaceFileSystemItemKind = switch kind {
            case .directory:
                .directory
            case .other:
                .other
            case .regularFile:
                .regularFile
            case .symbolicLink:
                .symbolicLink
            }
            return WorkspaceItemMutationExpectation(
                identity: WorkspaceFileSystemIdentity(device: device, inode: inode),
                kind: runtimeKind
            )
        }
    }

    enum Failure: String, Codable {
        case cancelled
        case commitPreparationFailed
        case crossDevice
        case destinationChanged
        case destinationExists
        case destinationInsideSource
        case differentRootAuthority
        case durabilityFailed
        case invalidName
        case namespaceChanged
        case recyclerFailed
        case rollbackFailed
        case sourceChanged
        case sourceMissing
        case unreadable

        init(_ failure: WorkspaceItemMutationFailure) {
            self = switch failure {
            case .cancelled:
                .cancelled
            case .commitPreparationFailed:
                .commitPreparationFailed
            case .crossDevice:
                .crossDevice
            case .destinationChanged:
                .destinationChanged
            case .destinationExists:
                .destinationExists
            case .destinationInsideSource:
                .destinationInsideSource
            case .differentRootAuthority:
                .differentRootAuthority
            case .durabilityFailed:
                .durabilityFailed
            case .invalidName:
                .invalidName
            case .namespaceChanged:
                .namespaceChanged
            case .recyclerFailed:
                .recyclerFailed
            case .rollbackFailed:
                .rollbackFailed
            case .sourceChanged:
                .sourceChanged
            case .sourceMissing:
                .sourceMissing
            case .unreadable:
                .unreadable
            }
        }

        var runtimeValue: WorkspaceItemMutationFailure {
            switch self {
            case .cancelled:
                .cancelled
            case .commitPreparationFailed:
                .commitPreparationFailed
            case .crossDevice:
                .crossDevice
            case .destinationChanged:
                .destinationChanged
            case .destinationExists:
                .destinationExists
            case .destinationInsideSource:
                .destinationInsideSource
            case .differentRootAuthority:
                .differentRootAuthority
            case .durabilityFailed:
                .durabilityFailed
            case .invalidName:
                .invalidName
            case .namespaceChanged:
                .namespaceChanged
            case .recyclerFailed:
                .recyclerFailed
            case .rollbackFailed:
                .rollbackFailed
            case .sourceChanged:
                .sourceChanged
            case .sourceMissing:
                .sourceMissing
            case .unreadable:
                .unreadable
            }
        }
    }

    enum CreationKind: String, Codable {
        case file
        case folder
    }

    enum CreationRecoveryState: Codable, Equatable {
        case none
        case removalIndeterminate(relativePath: String)
        case retained(relativePath: String)
        case unknown
    }

    enum CreationPublicationPhase: String, Codable, Equatable {
        case planned
        case prepared
        case committedCleanup
    }

    enum TrashCleanupState: Codable, Equatable {
        case notCreated
        case removalIndeterminate(relativePath: String)
        case removed
    }

    enum TrashSessionCommitPhase: String, Codable, Equatable {
        case pendingSessionCommit
        case committedCleanup
    }

    struct Creation: Codable, Equatable {
        let destinationRelativePath: String
        let kind: CreationKind
        let parentExpectation: Expectation?
        /// Exact publication slot authority. The bookmark names the original destination
        /// parent and the leaf preserves the literal spelling selected by the user.
        let destinationParentBookmarkData: Data?
        let destinationParentDisplayURL: URL?
        let destinationLeafName: String?
        let destinationParentAuthorityExpectation: Expectation?
        /// Optional for backward-compatible decoding. Absence is an unknown publication phase
        /// and must never be inferred from `isPlanned` or filesystem observation.
        let publicationPhase: CreationPublicationPhase?
        let isPlanned: Bool?
        let expectedCreatedItem: Expectation?
        /// Restart-durable authority for the prepared artifact. This bookmark is captured and
        /// resolved before WorkspaceKit is allowed to publish the staging entry.
        let createdItemBookmarkData: Data?
        let createdItemDisplayURL: URL?
        let reason: Failure
        let recoveryState: CreationRecoveryState
        let recoveryExpectation: Expectation?
        let publicationSourceRelativePath: String?
        let actualPublishedExpectation: Expectation?

        init(
            destinationRelativePath: String,
            kind: CreationKind,
            parentExpectation: Expectation? = nil,
            destinationParentBookmarkData: Data? = nil,
            destinationParentDisplayURL: URL? = nil,
            destinationLeafName: String? = nil,
            destinationParentAuthorityExpectation: Expectation? = nil,
            publicationPhase: CreationPublicationPhase? = nil,
            isPlanned: Bool? = nil,
            expectedCreatedItem: Expectation?,
            createdItemBookmarkData: Data? = nil,
            createdItemDisplayURL: URL? = nil,
            reason: Failure,
            recoveryState: CreationRecoveryState,
            recoveryExpectation: Expectation?,
            publicationSourceRelativePath: String?,
            actualPublishedExpectation: Expectation?
        ) {
            self.destinationRelativePath = destinationRelativePath
            self.kind = kind
            self.parentExpectation = parentExpectation
            self.destinationParentBookmarkData = destinationParentBookmarkData
            self.destinationParentDisplayURL = destinationParentDisplayURL
            self.destinationLeafName = destinationLeafName
            self.destinationParentAuthorityExpectation =
                destinationParentAuthorityExpectation
            self.publicationPhase = publicationPhase
            self.isPlanned = isPlanned
            self.expectedCreatedItem = expectedCreatedItem
            self.createdItemBookmarkData = createdItemBookmarkData
            self.createdItemDisplayURL = createdItemDisplayURL
            self.reason = reason
            self.recoveryState = recoveryState
            self.recoveryExpectation = recoveryExpectation
            self.publicationSourceRelativePath = publicationSourceRelativePath
            self.actualPublishedExpectation = actualPublishedExpectation
        }

        var destinationLocatorParentExpectation: Expectation? {
            destinationParentAuthorityExpectation ?? parentExpectation
        }

        func replacingDestinationParentLocator(
            bookmarkData: Data,
            displayURL: URL,
            leafName: String,
            parentExpectation: Expectation
        ) -> Creation {
            Creation(
                destinationRelativePath: destinationRelativePath,
                kind: kind,
                parentExpectation: self.parentExpectation,
                destinationParentBookmarkData: bookmarkData,
                destinationParentDisplayURL: displayURL,
                destinationLeafName: leafName,
                destinationParentAuthorityExpectation: parentExpectation,
                publicationPhase: publicationPhase,
                isPlanned: isPlanned,
                expectedCreatedItem: expectedCreatedItem,
                createdItemBookmarkData: createdItemBookmarkData,
                createdItemDisplayURL: createdItemDisplayURL,
                reason: reason,
                recoveryState: recoveryState,
                recoveryExpectation: recoveryExpectation,
                publicationSourceRelativePath: publicationSourceRelativePath,
                actualPublishedExpectation: actualPublishedExpectation
            )
        }

        func replacingCreatedItemAuthority(
            bookmarkData: Data,
            displayURL: URL
        ) -> Creation {
            Creation(
                destinationRelativePath: destinationRelativePath,
                kind: kind,
                parentExpectation: parentExpectation,
                destinationParentBookmarkData: destinationParentBookmarkData,
                destinationParentDisplayURL: destinationParentDisplayURL,
                destinationLeafName: destinationLeafName,
                destinationParentAuthorityExpectation:
                destinationParentAuthorityExpectation,
                publicationPhase: publicationPhase,
                isPlanned: isPlanned,
                expectedCreatedItem: expectedCreatedItem,
                createdItemBookmarkData: bookmarkData,
                createdItemDisplayURL: displayURL,
                reason: reason,
                recoveryState: recoveryState,
                recoveryExpectation: recoveryExpectation,
                publicationSourceRelativePath: publicationSourceRelativePath,
                actualPublishedExpectation: actualPublishedExpectation
            )
        }
    }

    struct Trash: Codable, Equatable {
        let sourceRelativePath: String
        let expectation: Expectation
        let sourceParentExpectation: Expectation
        /// Exact original source slot authority. Recovery may inspect an item bookmark as
        /// supplementary identity evidence, but mutation requires this parent bookmark plus the
        /// literal leaf spelling so a hard-link alias cannot redirect the operation.
        let sourceParentBookmarkData: Data?
        let sourceParentDisplayURL: URL?
        let sourceLeafName: String?
        let sourceParentAuthorityExpectation: Expectation?
        /// Restart-durable authority for the expected item while an automatic recovery rename
        /// is in flight. The URL is diagnostics only; bookmark resolution and exact identity
        /// validation are required before this locator can authorize reconciliation.
        let expectedItemBookmarkData: Data?
        let expectedItemDisplayURL: URL?
        /// Optional for backward-compatible decoding. Absence is an unknown commit phase and
        /// must never be inferred to mean that the App session commit is still pending.
        let sessionCommitPhase: TrashSessionCommitPhase?
        let reason: Failure
        let recoveryRelativePath: String?
        let reportedTrashURL: URL?
        let reportedTrashBookmarkData: Data?
        let cleanupState: TrashCleanupState
        let actualStagedExpectation: Expectation?
        let actualStagedEntryRecoveryRelativePath: String?

        init(
            sourceRelativePath: String,
            expectation: Expectation,
            sourceParentExpectation: Expectation,
            sourceParentBookmarkData: Data? = nil,
            sourceParentDisplayURL: URL? = nil,
            sourceLeafName: String? = nil,
            sourceParentAuthorityExpectation: Expectation? = nil,
            expectedItemBookmarkData: Data? = nil,
            expectedItemDisplayURL: URL? = nil,
            sessionCommitPhase: TrashSessionCommitPhase? = nil,
            reason: Failure,
            recoveryRelativePath: String?,
            reportedTrashURL: URL?,
            reportedTrashBookmarkData: Data?,
            cleanupState: TrashCleanupState,
            actualStagedExpectation: Expectation?,
            actualStagedEntryRecoveryRelativePath: String?
        ) {
            self.sourceRelativePath = sourceRelativePath
            self.expectation = expectation
            self.sourceParentExpectation = sourceParentExpectation
            self.sourceParentBookmarkData = sourceParentBookmarkData
            self.sourceParentDisplayURL = sourceParentDisplayURL
            self.sourceLeafName = sourceLeafName
            self.sourceParentAuthorityExpectation = sourceParentAuthorityExpectation
            self.expectedItemBookmarkData = expectedItemBookmarkData
            self.expectedItemDisplayURL = expectedItemDisplayURL
            self.sessionCommitPhase = sessionCommitPhase
            self.reason = reason
            self.recoveryRelativePath = recoveryRelativePath
            self.reportedTrashURL = reportedTrashURL
            self.reportedTrashBookmarkData = reportedTrashBookmarkData
            self.cleanupState = cleanupState
            self.actualStagedExpectation = actualStagedExpectation
            self.actualStagedEntryRecoveryRelativePath =
                actualStagedEntryRecoveryRelativePath
        }

        func replacingReportedTrashAuthority(
            bookmarkData: Data,
            displayURL: URL
        ) -> Trash {
            Trash(
                sourceRelativePath: sourceRelativePath,
                expectation: expectation,
                sourceParentExpectation: sourceParentExpectation,
                sourceParentBookmarkData: sourceParentBookmarkData,
                sourceParentDisplayURL: sourceParentDisplayURL,
                sourceLeafName: sourceLeafName,
                sourceParentAuthorityExpectation: sourceParentAuthorityExpectation,
                expectedItemBookmarkData: expectedItemBookmarkData,
                expectedItemDisplayURL: expectedItemDisplayURL,
                sessionCommitPhase: sessionCommitPhase,
                reason: reason,
                recoveryRelativePath: recoveryRelativePath,
                reportedTrashURL: displayURL,
                reportedTrashBookmarkData: bookmarkData,
                cleanupState: cleanupState,
                actualStagedExpectation: actualStagedExpectation,
                actualStagedEntryRecoveryRelativePath:
                actualStagedEntryRecoveryRelativePath
            )
        }

        var sourceLocatorParentExpectation: Expectation {
            sourceParentAuthorityExpectation ?? sourceParentExpectation
        }

        func replacingSourceParentLocator(
            bookmarkData: Data,
            displayURL: URL,
            leafName: String,
            parentExpectation: Expectation
        ) -> Trash {
            Trash(
                sourceRelativePath: sourceRelativePath,
                expectation: expectation,
                sourceParentExpectation: sourceParentExpectation,
                sourceParentBookmarkData: bookmarkData,
                sourceParentDisplayURL: displayURL,
                sourceLeafName: leafName,
                sourceParentAuthorityExpectation: parentExpectation,
                expectedItemBookmarkData: expectedItemBookmarkData,
                expectedItemDisplayURL: expectedItemDisplayURL,
                sessionCommitPhase: sessionCommitPhase,
                reason: reason,
                recoveryRelativePath: recoveryRelativePath,
                reportedTrashURL: reportedTrashURL,
                reportedTrashBookmarkData: reportedTrashBookmarkData,
                cleanupState: cleanupState,
                actualStagedExpectation: actualStagedExpectation,
                actualStagedEntryRecoveryRelativePath:
                actualStagedEntryRecoveryRelativePath
            )
        }

        func replacingExpectedItemAuthority(
            bookmarkData: Data,
            displayURL: URL
        ) -> Trash {
            Trash(
                sourceRelativePath: sourceRelativePath,
                expectation: expectation,
                sourceParentExpectation: sourceParentExpectation,
                sourceParentBookmarkData: sourceParentBookmarkData,
                sourceParentDisplayURL: sourceParentDisplayURL,
                sourceLeafName: sourceLeafName,
                sourceParentAuthorityExpectation: sourceParentAuthorityExpectation,
                expectedItemBookmarkData: bookmarkData,
                expectedItemDisplayURL: displayURL,
                sessionCommitPhase: sessionCommitPhase,
                reason: reason,
                recoveryRelativePath: recoveryRelativePath,
                reportedTrashURL: reportedTrashURL,
                reportedTrashBookmarkData: reportedTrashBookmarkData,
                cleanupState: cleanupState,
                actualStagedExpectation: actualStagedExpectation,
                actualStagedEntryRecoveryRelativePath:
                actualStagedEntryRecoveryRelativePath
            )
        }
    }

    enum Payload: Codable, Equatable {
        case creation(Creation)
        case relocation(Relocation)
        case trash(Trash)
    }

    let id: UUID
    let updatedAt: Date
    let rootBookmarkData: Data
    let rootDisplayURL: URL
    let rootExpectation: Expectation
    let payload: Payload
    let textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord]

    var operation: WorkspaceMutationRecoveryOperation {
        switch payload {
        case .creation:
            .creation
        case .relocation:
            .relocation
        case .trash:
            .trash
        }
    }

    var sourceURL: URL {
        let relativePath = switch payload {
        case let .creation(context):
            context.destinationRelativePath
        case let .relocation(context):
            context.sourceRelativePath
        case let .trash(context):
            context.sourceRelativePath
        }
        return rootDisplayURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Display-root candidates are only an App ownership reservation until the bookmark is
    /// restored. They are never filesystem authority, but they prevent a new mutation from
    /// claiming a path that an unloaded or unavailable recovery record still owns.
    var workspaceOwnedCandidateDisplayURLs: [URL] {
        var relativePaths: [String]
        var retainedDisplayURLs: [URL] = []
        switch payload {
        case let .creation(context):
            relativePaths = [context.destinationRelativePath]
            switch context.recoveryState {
            case .none, .unknown:
                break
            case let .removalIndeterminate(relativePath),
                 let .retained(relativePath):
                relativePaths.append(relativePath)
            }
            if let publicationSourceRelativePath = context.publicationSourceRelativePath {
                relativePaths.append(publicationSourceRelativePath)
            }
            if let createdItemDisplayURL = context.createdItemDisplayURL {
                retainedDisplayURLs.append(createdItemDisplayURL)
            }
            if let destinationParentDisplayURL = context.destinationParentDisplayURL,
               let destinationLeafName = context.destinationLeafName
            {
                retainedDisplayURLs.append(
                    destinationParentDisplayURL.appendingPathComponent(
                        destinationLeafName,
                        isDirectory: context.kind == .folder
                    )
                )
            }
        case let .relocation(context):
            relativePaths = [context.sourceRelativePath, context.destinationRelativePath]
            if let sourceParentDisplayURL = context.sourceParentDisplayURL,
               let sourceLeafName = context.sourceLeafName
            {
                retainedDisplayURLs.append(
                    sourceParentDisplayURL.appendingPathComponent(sourceLeafName)
                )
            }
            if let destinationParentDisplayURL = context.destinationParentDisplayURL,
               let destinationLeafName = context.destinationLeafName
            {
                retainedDisplayURLs.append(
                    destinationParentDisplayURL.appendingPathComponent(destinationLeafName)
                )
            }
            if let relocatedItemDisplayURL = context.relocatedItemDisplayURL {
                retainedDisplayURLs.append(relocatedItemDisplayURL)
            }
        case let .trash(context):
            relativePaths = [context.sourceRelativePath]
            if let recoveryRelativePath = context.recoveryRelativePath {
                relativePaths.append(recoveryRelativePath)
            }
            if case let .removalIndeterminate(relativePath) = context.cleanupState {
                relativePaths.append(relativePath)
            }
            if let recoveryRelativePath = context.actualStagedEntryRecoveryRelativePath {
                relativePaths.append(recoveryRelativePath)
            }
            if let sourceParentDisplayURL = context.sourceParentDisplayURL,
               let sourceLeafName = context.sourceLeafName
            {
                retainedDisplayURLs.append(
                    sourceParentDisplayURL.appendingPathComponent(sourceLeafName)
                )
            }
            if let expectedItemDisplayURL = context.expectedItemDisplayURL {
                retainedDisplayURLs.append(expectedItemDisplayURL)
            }
            if let reportedTrashURL = context.reportedTrashURL {
                retainedDisplayURLs.append(reportedTrashURL)
            }
        }
        return relativePaths.map {
            rootDisplayURL.appendingPathComponent($0, isDirectory: false)
        } + retainedDisplayURLs + textRecoveryRecords.map(\.originalURL)
    }

    func replacingPayload(
        _ payload: Payload,
        textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord],
        updatedAt: Date = Date()
    ) -> WorkspaceMutationOperationRecoveryRecord {
        WorkspaceMutationOperationRecoveryRecord(
            id: id,
            updatedAt: updatedAt,
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: rootDisplayURL,
            rootExpectation: rootExpectation,
            payload: payload,
            textRecoveryRecords: textRecoveryRecords
        )
    }

    func replacingRootBookmark(
        _ rootBookmarkData: Data,
        rootDisplayURL: URL,
        updatedAt: Date = Date()
    ) -> WorkspaceMutationOperationRecoveryRecord {
        WorkspaceMutationOperationRecoveryRecord(
            id: id,
            updatedAt: updatedAt,
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: rootDisplayURL,
            rootExpectation: rootExpectation,
            payload: payload,
            textRecoveryRecords: textRecoveryRecords
        )
    }
}

extension WorkspaceMutationOperationRecoveryRecord {
    enum RelocationSessionCommitPhase: String, Codable, Equatable {
        case pendingSessionCommit
        case committedCleanup
    }

    struct Relocation: Codable, Equatable {
        let sourceRelativePath: String
        let destinationRelativePath: String
        let expectation: Expectation
        let sourceParentExpectation: Expectation
        let destinationParentExpectation: Expectation
        /// Exact source slot authority: a parent bookmark plus literal leaf name. The display
        /// URL is diagnostics only. The optional expectation can diverge from the operation's
        /// original source parent as recovery alternates which retained slot owns the item.
        let sourceParentBookmarkData: Data?
        let sourceParentDisplayURL: URL?
        let sourceLeafName: String?
        let sourceParentAuthorityExpectation: Expectation?
        /// Restart-durable authority for the exact destination parent captured before
        /// publication. The display URL is diagnostics/UI only and must never be used to
        /// reconstruct filesystem authority when the bookmark is unavailable.
        let destinationParentBookmarkData: Data?
        let destinationParentDisplayURL: URL?
        /// Literal final component paired with `destinationParentBookmarkData`. Keeping the
        /// leaf separate avoids re-parsing a stale root-relative display path after the parent
        /// moves outside the workspace.
        let destinationLeafName: String?
        let destinationParentAuthorityExpectation: Expectation?
        /// Supplementary relocated-item identity. Hard links mean this cannot be the sole
        /// mutation authority; recovery must use a validated parent bookmark plus literal leaf.
        let relocatedItemBookmarkData: Data?
        let relocatedItemDisplayURL: URL?
        /// Optional only for backward-compatible decoding. Absence is an unknown commit phase,
        /// never evidence that the session commit is still pending.
        let sessionCommitPhase: RelocationSessionCommitPhase?
        let reason: Failure
        let actualMovedExpectation: Expectation?

        init(
            sourceRelativePath: String,
            destinationRelativePath: String,
            expectation: Expectation,
            sourceParentExpectation: Expectation,
            destinationParentExpectation: Expectation,
            sourceParentBookmarkData: Data? = nil,
            sourceParentDisplayURL: URL? = nil,
            sourceLeafName: String? = nil,
            sourceParentAuthorityExpectation: Expectation? = nil,
            destinationParentBookmarkData: Data? = nil,
            destinationParentDisplayURL: URL? = nil,
            destinationLeafName: String? = nil,
            destinationParentAuthorityExpectation: Expectation? = nil,
            relocatedItemBookmarkData: Data? = nil,
            relocatedItemDisplayURL: URL? = nil,
            sessionCommitPhase: RelocationSessionCommitPhase? = nil,
            reason: Failure,
            actualMovedExpectation: Expectation?
        ) {
            self.sourceRelativePath = sourceRelativePath
            self.destinationRelativePath = destinationRelativePath
            self.expectation = expectation
            self.sourceParentExpectation = sourceParentExpectation
            self.destinationParentExpectation = destinationParentExpectation
            self.sourceParentBookmarkData = sourceParentBookmarkData
            self.sourceParentDisplayURL = sourceParentDisplayURL
            self.sourceLeafName = sourceLeafName
            self.sourceParentAuthorityExpectation = sourceParentAuthorityExpectation
            self.destinationParentBookmarkData = destinationParentBookmarkData
            self.destinationParentDisplayURL = destinationParentDisplayURL
            self.destinationLeafName = destinationLeafName
            self.destinationParentAuthorityExpectation =
                destinationParentAuthorityExpectation
            self.relocatedItemBookmarkData = relocatedItemBookmarkData
            self.relocatedItemDisplayURL = relocatedItemDisplayURL
            self.sessionCommitPhase = sessionCommitPhase
            self.reason = reason
            self.actualMovedExpectation = actualMovedExpectation
        }

        var sourceLocatorParentExpectation: Expectation {
            sourceParentAuthorityExpectation ?? sourceParentExpectation
        }

        var destinationLocatorParentExpectation: Expectation {
            destinationParentAuthorityExpectation ?? destinationParentExpectation
        }
    }
}

extension WorkspaceMutationOperationRecoveryRecord.Relocation {
    func replacingSourceParentLocator(
        bookmarkData: Data,
        displayURL: URL,
        leafName: String,
        parentExpectation: WorkspaceMutationOperationRecoveryRecord.Expectation
    ) -> Self {
        Self(
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            sourceParentBookmarkData: bookmarkData,
            sourceParentDisplayURL: displayURL,
            sourceLeafName: leafName,
            sourceParentAuthorityExpectation: parentExpectation,
            destinationParentBookmarkData: destinationParentBookmarkData,
            destinationParentDisplayURL: destinationParentDisplayURL,
            destinationLeafName: destinationLeafName,
            destinationParentAuthorityExpectation:
            destinationParentAuthorityExpectation,
            relocatedItemBookmarkData: relocatedItemBookmarkData,
            relocatedItemDisplayURL: relocatedItemDisplayURL,
            sessionCommitPhase: sessionCommitPhase,
            reason: reason,
            actualMovedExpectation: actualMovedExpectation
        )
    }

    func replacingDestinationParentLocator(
        bookmarkData: Data,
        displayURL: URL,
        leafName: String,
        parentExpectation: WorkspaceMutationOperationRecoveryRecord.Expectation
    ) -> Self {
        Self(
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            sourceParentBookmarkData: sourceParentBookmarkData,
            sourceParentDisplayURL: sourceParentDisplayURL,
            sourceLeafName: sourceLeafName,
            sourceParentAuthorityExpectation: sourceParentAuthorityExpectation,
            destinationParentBookmarkData: bookmarkData,
            destinationParentDisplayURL: displayURL,
            destinationLeafName: leafName,
            destinationParentAuthorityExpectation: parentExpectation,
            relocatedItemBookmarkData: relocatedItemBookmarkData,
            relocatedItemDisplayURL: relocatedItemDisplayURL,
            sessionCommitPhase: sessionCommitPhase,
            reason: reason,
            actualMovedExpectation: actualMovedExpectation
        )
    }

    func replacingRelocatedItemAuthority(
        bookmarkData: Data,
        displayURL: URL
    ) -> Self {
        Self(
            sourceRelativePath: sourceRelativePath,
            destinationRelativePath: destinationRelativePath,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            sourceParentBookmarkData: sourceParentBookmarkData,
            sourceParentDisplayURL: sourceParentDisplayURL,
            sourceLeafName: sourceLeafName,
            sourceParentAuthorityExpectation: sourceParentAuthorityExpectation,
            destinationParentBookmarkData: destinationParentBookmarkData,
            destinationParentDisplayURL: destinationParentDisplayURL,
            destinationLeafName: destinationLeafName,
            destinationParentAuthorityExpectation:
            destinationParentAuthorityExpectation,
            relocatedItemBookmarkData: bookmarkData,
            relocatedItemDisplayURL: displayURL,
            sessionCommitPhase: sessionCommitPhase,
            reason: reason,
            actualMovedExpectation: actualMovedExpectation
        )
    }
}

protocol WorkspaceMutationOperationRecoveryPersisting: AnyObject {
    func load() throws -> [WorkspaceMutationOperationRecoveryRecord]
    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws
    func remove(id: UUID) throws
    func quarantineAfterLoadFailure() throws
}

extension WorkspaceMutationOperationRecoveryPersisting {
    func quarantineAfterLoadFailure() throws {}
}

final class WorkspaceMutationOperationRecoveryStore: WorkspaceMutationOperationRecoveryPersisting {
    static let applicationSupportDirectoryName = "Plainsong"
    static let recoveryDirectoryName = "WorkspaceMutationOperationRecovery"

    private let directoryURL: URL
    private let directoryDurabilityBoundaryURL: URL
    private let fileManager: FileManager
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder
    private var didDurablyEnsureRecoveryDirectory = false

    convenience init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directoryURL = applicationSupportURL
            .appendingPathComponent(Self.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
        self.init(
            directoryURL: directoryURL,
            fileManager: fileManager,
            directoryDurabilityBoundaryURL: applicationSupportURL
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        directoryDurabilityBoundaryURL: URL? = nil
    ) {
        self.directoryURL = directoryURL
        self.directoryDurabilityBoundaryURL =
            directoryDurabilityBoundaryURL
                ?? directoryURL.deletingLastPathComponent()
        self.fileManager = fileManager
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        decoder = PropertyListDecoder()
    }

    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(
                .fileReadInvalidFileName,
                userInfo: [NSFilePathErrorKey: directoryURL.path]
            )
        }

        let recordURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var records: [WorkspaceMutationOperationRecoveryRecord] = []
        for recordURL in recordURLs.sorted(by: Self.fileURLSort)
            where recordURL.pathExtension == "plist"
        {
            do {
                let values = try recordURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let filenameID = Self.recordID(for: recordURL)
                else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSFilePathErrorKey: recordURL.path]
                    )
                }
                let record = try decoder.decode(
                    WorkspaceMutationOperationRecoveryRecord.self,
                    from: Data(contentsOf: recordURL)
                )
                guard record.id == filenameID else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSFilePathErrorKey: recordURL.path]
                    )
                }
                records.append(record)
            } catch {
                // Preserve the malformed record untouched, but surface the load failure so
                // startup remains recovery-first and does not auto-open another document.
                throw error
            }
        }
        return records.sorted(by: Self.recordSort)
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws {
        try ensureRecoveryDirectory()
        let destination = recordURL(for: record.id)
        try WorkspaceMutationRecoveryDurableFileStore.write(
            encoder.encode(record),
            to: destination,
            directoryURL: directoryURL
        )
    }

    func remove(id: UUID) throws {
        try WorkspaceMutationRecoveryDurableFileStore.remove(
            recordURL(for: id),
            directoryURL: directoryURL
        )
    }

    func quarantineAfterLoadFailure() throws {
        try WorkspaceMutationRecoveryDurableFileStore.quarantineRecoveryDirectory(
            directoryURL
        )
        didDurablyEnsureRecoveryDirectory = false
    }

    static func recordFilename(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).plist"
    }

    private func ensureRecoveryDirectory() throws {
        try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
            directoryURL,
            existingHierarchyDurabilityBoundaryURL:
            directoryDurabilityBoundaryURL,
            synchronizeExistingHierarchy:
            !didDurablyEnsureRecoveryDirectory
        )
        didDurablyEnsureRecoveryDirectory = true
    }

    private func recordURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(Self.recordFilename(for: id), isDirectory: false)
    }

    private static func recordID(for url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private static func fileURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
    }

    private static func recordSort(
        _ lhs: WorkspaceMutationOperationRecoveryRecord,
        _ rhs: WorkspaceMutationOperationRecoveryRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
    }
}
