// swiftlint:disable file_length
import Foundation
import MarkdownCore
import WorkspaceKit

enum WorkspaceMutationRecoveryOperation: Equatable {
    case creation
    case relocation
    case textRecovery
    case trash
}

enum WorkspaceMutationRecoverySecondaryAction: Equatable {
    case keepEditorCopy
    case showEditorCopy
    case stopTracking
}

struct WorkspaceMutationReconciliationPrompt: Equatable {
    let recoveryID: UUID
    let operation: WorkspaceMutationRecoveryOperation
    let sourceURL: URL
    let secondaryAction: WorkspaceMutationRecoverySecondaryAction
}

struct WorkspaceCreationRecoveryContext {
    let id: UUID
    let destination: WorkspaceFileSystemLocation
    let kind: AppState.WorkspaceCreationKind
    let parentExpectation: WorkspaceItemMutationExpectation?
    var destinationParentBookmarkData: Data?
    var destinationParentDisplayURL: URL?
    var destinationLeafName: String?
    var destinationParentAuthorityExpectation: WorkspaceItemMutationExpectation?
    var destinationParentAuthorityLocation: WorkspaceFileSystemLocation?
    var publicationState: WorkspaceCreationPublicationState = .unknown
    var isPlanned: Bool
    var expectedCreatedItem: WorkspaceItemMutationExpectation?
    var reason: WorkspaceItemMutationFailure
    var recoveryState: WorkspaceItemCreationRecoveryState
    var recoveryExpectation: WorkspaceItemMutationExpectation?
    var publicationSource: WorkspaceFileSystemLocation?
    var createdItemBookmarkData: Data?
    var createdItemDisplayURL: URL?
    var createdItemAuthorityLocation: WorkspaceFileSystemLocation?
    var actualPublishedExpectation: WorkspaceItemMutationExpectation?

    var destinationParentAuthorityIsUnresolved: Bool {
        destinationParentBookmarkData != nil &&
            destinationParentAuthorityLocation == nil
    }

    var createdItemAuthorityIsUnresolved: Bool {
        createdItemBookmarkData != nil && createdItemAuthorityLocation == nil
    }
}

enum WorkspaceCreationPublicationState: Equatable {
    case unknown
    case planned
    case prepared
    case committed
}

struct WorkspaceRelocationRecoveryContext {
    let id: UUID
    let source: WorkspaceFileSystemLocation
    let destination: WorkspaceFileSystemLocation
    let expectation: WorkspaceItemMutationExpectation
    let sourceParentExpectation: WorkspaceItemMutationExpectation
    let destinationParentExpectation: WorkspaceItemMutationExpectation
    var sourceParentBookmarkData: Data?
    var sourceParentDisplayURL: URL?
    var sourceLeafName: String?
    var sourceParentAuthorityExpectation: WorkspaceItemMutationExpectation
    var sourceParentAuthorityLocation: WorkspaceFileSystemLocation?
    var destinationParentBookmarkData: Data?
    var destinationParentDisplayURL: URL?
    var destinationLeafName: String?
    var destinationParentAuthorityExpectation: WorkspaceItemMutationExpectation
    var destinationParentAuthorityLocation: WorkspaceFileSystemLocation?
    var relocatedItemBookmarkData: Data?
    var relocatedItemDisplayURL: URL?
    var relocatedItemAuthorityLocation: WorkspaceFileSystemLocation?
    var sessionCommitState: WorkspaceRelocationSessionCommitState
    var reason: WorkspaceItemMutationFailure
    var actualMovedExpectation: WorkspaceItemMutationExpectation?
    let records: [AppState.WorkspaceSessionRelocationRecord]
    var remainingSessionIDs: Set<ObjectIdentifier>
}

enum WorkspaceRelocationSessionCommitState: Equatable {
    case unknown
    case pending
    case committed
}

struct WorkspaceTrashRecoveryContext {
    let id: UUID
    let source: WorkspaceFileSystemLocation
    let expectation: WorkspaceItemMutationExpectation
    let sourceParentExpectation: WorkspaceItemMutationExpectation
    var sourceParentBookmarkData: Data?
    var sourceParentDisplayURL: URL?
    var sourceLeafName: String?
    var sourceParentAuthorityExpectation: WorkspaceItemMutationExpectation
    var sourceParentAuthorityLocation: WorkspaceFileSystemLocation?
    var expectedItemBookmarkData: Data?
    var expectedItemDisplayURL: URL?
    var expectedItemAuthorityLocation: WorkspaceFileSystemLocation?
    var sessionCommitState: WorkspaceTrashSessionCommitState
    var reason: WorkspaceItemMutationFailure
    var recoveryLocation: WorkspaceFileSystemLocation?
    var reportedTrashURL: URL?
    var reportedTrashBookmarkData: Data?
    var reportedTrashAuthorityLocation: WorkspaceFileSystemLocation?
    var cleanupState: WorkspaceTrashStagingCleanupState
    var actualStagedExpectation: WorkspaceItemMutationExpectation?
    var actualStagedEntryRecoveryLocation: WorkspaceFileSystemLocation?
    let records: [AppState.WorkspaceTrashSessionRecord]
    var remainingSessionIDs: Set<ObjectIdentifier>

    init(
        id: UUID,
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        sourceParentBookmarkData: Data? = nil,
        sourceParentDisplayURL: URL? = nil,
        sourceLeafName: String? = nil,
        sourceParentAuthorityExpectation: WorkspaceItemMutationExpectation? = nil,
        sourceParentAuthorityLocation: WorkspaceFileSystemLocation? = nil,
        expectedItemBookmarkData: Data? = nil,
        expectedItemDisplayURL: URL? = nil,
        expectedItemAuthorityLocation: WorkspaceFileSystemLocation? = nil,
        sessionCommitState: WorkspaceTrashSessionCommitState = .unknown,
        reason: WorkspaceItemMutationFailure,
        recoveryLocation: WorkspaceFileSystemLocation?,
        reportedTrashURL: URL?,
        reportedTrashBookmarkData: Data?,
        reportedTrashAuthorityLocation: WorkspaceFileSystemLocation?,
        cleanupState: WorkspaceTrashStagingCleanupState,
        actualStagedExpectation: WorkspaceItemMutationExpectation?,
        actualStagedEntryRecoveryLocation: WorkspaceFileSystemLocation?,
        records: [AppState.WorkspaceTrashSessionRecord],
        remainingSessionIDs: Set<ObjectIdentifier>
    ) {
        self.id = id
        self.source = source
        self.expectation = expectation
        self.sourceParentExpectation = sourceParentExpectation
        self.sourceParentBookmarkData = sourceParentBookmarkData
        self.sourceParentDisplayURL = sourceParentDisplayURL
        self.sourceLeafName = sourceLeafName
        self.sourceParentAuthorityExpectation =
            sourceParentAuthorityExpectation ?? sourceParentExpectation
        self.sourceParentAuthorityLocation = sourceParentAuthorityLocation
        self.expectedItemBookmarkData = expectedItemBookmarkData
        self.expectedItemDisplayURL = expectedItemDisplayURL
        self.expectedItemAuthorityLocation = expectedItemAuthorityLocation
        self.sessionCommitState = sessionCommitState
        self.reason = reason
        self.recoveryLocation = recoveryLocation
        self.reportedTrashURL = reportedTrashURL
        self.reportedTrashBookmarkData = reportedTrashBookmarkData
        self.reportedTrashAuthorityLocation = reportedTrashAuthorityLocation
        self.cleanupState = cleanupState
        self.actualStagedExpectation = actualStagedExpectation
        self.actualStagedEntryRecoveryLocation = actualStagedEntryRecoveryLocation
        self.records = records
        self.remainingSessionIDs = remainingSessionIDs
    }

    var stagingCleanupLocation: WorkspaceFileSystemLocation? {
        guard case let .removalIndeterminate(location) = cleanupState else { return nil }
        return location
    }

    /// A persisted locator that failed restart validation must never fall back to its display
    /// URL. Recovery callers use this distinction to remain fail-closed instead of treating an
    /// unavailable bookmark as if no authority had ever been captured.
    var expectedItemAuthorityIsUnresolved: Bool {
        expectedItemBookmarkData != nil && expectedItemAuthorityLocation == nil
    }

    var sourceParentAuthorityIsUnresolved: Bool {
        sourceParentBookmarkData != nil && sourceParentAuthorityLocation == nil
    }

    var reportedTrashAuthorityIsUnresolved: Bool {
        reportedTrashBookmarkData != nil && reportedTrashAuthorityLocation == nil
    }
}

enum WorkspaceTrashSessionCommitState: Equatable {
    case unknown
    case pending
    case committed
}

struct WorkspaceUnavailableMutationRecoveryContext {
    let record: WorkspaceMutationOperationRecoveryRecord
    let failure: WorkspaceMutationOperationRecoveryError
}

enum WorkspaceMutationRecoveryContext {
    case creation(WorkspaceCreationRecoveryContext)
    case relocation(WorkspaceRelocationRecoveryContext)
    case trash(WorkspaceTrashRecoveryContext)
    case unavailable(WorkspaceUnavailableMutationRecoveryContext)

    var id: UUID {
        switch self {
        case let .creation(context):
            context.id
        case let .relocation(context):
            context.id
        case let .trash(context):
            context.id
        case let .unavailable(context):
            context.record.id
        }
    }

    var operation: WorkspaceMutationRecoveryOperation {
        switch self {
        case .creation:
            .creation
        case .relocation:
            .relocation
        case .trash:
            .trash
        case let .unavailable(context):
            context.record.operation
        }
    }

    var sourceURL: URL {
        switch self {
        case let .creation(context):
            context.destination.fileURL
        case let .relocation(context):
            context.source.fileURL
        case let .trash(context):
            context.source.fileURL
        case let .unavailable(context):
            context.record.sourceURL
        }
    }

    var remainingSessionIDs: Set<ObjectIdentifier> {
        switch self {
        case .creation:
            []
        case let .relocation(context):
            context.remainingSessionIDs
        case let .trash(context):
            context.remainingSessionIDs
        case .unavailable:
            []
        }
    }

    var remainingSessions: [DocumentSession] {
        switch self {
        case .creation:
            []
        case let .relocation(context):
            context.records.compactMap { record in
                context.remainingSessionIDs.contains(ObjectIdentifier(record.session))
                    ? record.session
                    : nil
            }
        case let .trash(context):
            context.records.compactMap { record in
                context.remainingSessionIDs.contains(ObjectIdentifier(record.session))
                    ? record.session
                    : nil
            }
        case .unavailable:
            []
        }
    }

    var retainedCandidateLocations: [WorkspaceFileSystemLocation] {
        switch self {
        case let .creation(context):
            [context.destination] +
                [
                    context.destinationParentAuthorityLocation,
                    context.recoveryState.location,
                    context.publicationSource,
                    context.createdItemAuthorityLocation,
                ].compactMap { $0 }
        case let .relocation(context):
            [context.source, context.destination] +
                [
                    context.sourceParentAuthorityLocation,
                    context.destinationParentAuthorityLocation,
                    context.relocatedItemAuthorityLocation,
                ].compactMap { $0 }
        case let .trash(context):
            [context.source] + [
                context.sourceParentAuthorityLocation,
                context.expectedItemAuthorityLocation,
                context.recoveryLocation,
                context.reportedTrashAuthorityLocation,
                context.stagingCleanupLocation,
                context.actualStagedEntryRecoveryLocation,
            ].compactMap { $0 }
        case .unavailable:
            []
        }
    }
}

enum WorkspaceMutationReconciliationCompletion {
    case creation
    case relocation([AppState.WorkspaceSessionRelocationRecord])
    case trashFinished([AppState.WorkspaceTrashSessionRecord])
    case trashRestored([AppState.WorkspaceTrashSessionRecord])
}

@MainActor
extension AppState {
    func workspaceMutationRetainedRecoverySessions() -> [DocumentSession] {
        var sessions = workspaceMutationRecoveries.values.flatMap(\.remainingSessions)
        sessions.append(contentsOf: workspaceMutationTextRecoverySessions.values)
        var seen: Set<ObjectIdentifier> = []
        return sessions.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func nextWorkspaceMutationRecovery() -> WorkspaceMutationRecoveryContext? {
        workspaceMutationRecoveries.values.sorted {
            if $0.sourceURL.absoluteString == $1.sourceURL.absoluteString {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sourceURL.absoluteString < $1.sourceURL.absoluteString
        }.first
    }

    func installWorkspaceCreationRecovery(
        _ indeterminate: WorkspaceIndeterminateItemCreation,
        kind: WorkspaceCreationKind,
        recoveryID: UUID = UUID()
    ) {
        let recovery: WorkspaceMutationRecoveryContext = .creation(.init(
            id: recoveryID,
            destination: indeterminate.destination,
            kind: kind,
            parentExpectation: nil,
            isPlanned: false,
            expectedCreatedItem: indeterminate.createdExpectation,
            reason: indeterminate.reason,
            recoveryState: indeterminate.recoveryState,
            recoveryExpectation: indeterminate.recoveryExpectation,
            publicationSource: indeterminate.publicationSource,
            actualPublishedExpectation: indeterminate.actualPublishedExpectation
        ))
        do {
            try persistAndInstallWorkspaceMutationRecovery(recovery)
        } catch {
            workspaceMutationRecoveries[recoveryID] = recovery
            present(error, title: "Could Not Preserve Workspace Recovery")
        }
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func prepareWorkspaceCreationRecoveryIntent(
        plan: WorkspaceItemCreationPlan,
        kind: WorkspaceCreationKind
    ) throws -> WorkspaceCreationRecoveryContext {
        guard let stagingLocation = plan.stagingLocation else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(
                plan.destination.fileURL
            )
        }
        let destinationParentAuthority = try SecurityScopedAccess.withAccess(
            to: plan.destination.securityScopedURL
        ) {
            let standaloneDestination = try WorkspaceFileSystemLocation(
                fileURL: plan.destination.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneDestination.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneDestination.relativePath,
                expectingParent: plan.parentExpectation
            )
        }
        let context = WorkspaceCreationRecoveryContext(
            id: UUID(),
            destination: plan.destination,
            kind: kind,
            parentExpectation: plan.parentExpectation,
            destinationParentBookmarkData:
            destinationParentAuthority.bookmarkData,
            destinationParentDisplayURL: destinationParentAuthority.displayURL,
            destinationLeafName: destinationParentAuthority.location.relativePath,
            destinationParentAuthorityExpectation: plan.parentExpectation,
            destinationParentAuthorityLocation:
            destinationParentAuthority.location,
            publicationState: .planned,
            isPlanned: true,
            expectedCreatedItem: nil,
            reason: .namespaceChanged,
            recoveryState: .none,
            recoveryExpectation: nil,
            publicationSource: stagingLocation,
            actualPublishedExpectation: nil
        )
        try persistWorkspaceMutationRecoveryIntent(.creation(context))
        return context
    }

    func recordWorkspaceCreatedArtifact(
        _ artifact: WorkspacePreparedItemCreationArtifact,
        recoveryIntent: inout WorkspaceCreationRecoveryContext
    ) throws {
        var updated = recoveryIntent
        guard let publicationSource = updated.publicationSource,
              artifact.location == publicationSource
        else {
            throw WorkspaceMutationError.unexpectedDestination(
                artifact.location.fileURL
            )
        }
        let itemAuthority = try captureWorkspaceMutationItemBookmarkAuthority(
            at: artifact.location.fileURL,
            expecting: artifact.expectation
        )
        updated.expectedCreatedItem = artifact.expectation
        updated.recoveryState = .retained(artifact.location)
        updated.recoveryExpectation = artifact.expectation
        updated.publicationSource = artifact.location
        updated.createdItemBookmarkData = itemAuthority.bookmarkData
        updated.createdItemDisplayURL = itemAuthority.displayURL
        updated.createdItemAuthorityLocation = itemAuthority.location
        updated.publicationState = .prepared
        recoveryIntent = updated
        try persistWorkspaceMutationRecoveryIntent(.creation(updated))
    }

    func finishWorkspaceCreation(
        _ outcome: WorkspaceItemCreationOutcome,
        recoveryIntent: WorkspaceCreationRecoveryContext
    ) throws {
        switch outcome {
        case let .notCreated(failure):
            try finishWorkspaceCreationFailure(
                failure,
                recoveryIntent: recoveryIntent
            )
        case let .createdAndDurable(created):
            try finishDurableWorkspaceCreation(
                created,
                recoveryIntent: recoveryIntent
            )
        case let .creationStateIndeterminate(indeterminate):
            try finishIndeterminateWorkspaceCreation(
                indeterminate,
                recoveryIntent: recoveryIntent
            )
        }
    }

    private func finishWorkspaceCreationFailure(
        _ failure: WorkspaceItemMutationFailure,
        recoveryIntent: WorkspaceCreationRecoveryContext
    ) throws {
        var context = recoveryIntent
        context.isPlanned = false
        context.expectedCreatedItem = nil
        context.reason = failure
        context.recoveryState = .none
        context.recoveryExpectation = nil
        context.actualPublishedExpectation = nil
        try persistWorkspaceCreationOutcomeOrInstallRecovery(context)
        do {
            try releaseWorkspaceMutationRecovery(
                id: context.id,
                knownRecovery: .creation(context)
            )
        } catch {
            installWorkspaceCreationRecoveryContext(context)
            throw error
        }
        throw WorkspaceMutationError.operationFailed(
            failure,
            context.destination.fileURL
        )
    }

    private func finishDurableWorkspaceCreation(
        _ created: WorkspaceCreatedItem,
        recoveryIntent: WorkspaceCreationRecoveryContext
    ) throws {
        var context = recoveryIntent
        context.isPlanned = false
        context.expectedCreatedItem = created.expectation
        context.reason = .namespaceChanged
        context.recoveryState = .none
        context.recoveryExpectation = nil
        context.actualPublishedExpectation = nil
        do {
            context = try resolveWorkspaceCreationAuthorities(context)
            guard workspaceCreationPublishedOutcomeIsProven(
                context,
                expecting: created.expectation
            ) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    .namespaceChanged
                )
            }
            context.publicationState = .committed
            try persistWorkspaceCreationOutcomeOrInstallRecovery(context)
            context = try resolveWorkspaceCreationAuthorities(context)
            guard context.publicationState == .committed,
                  workspaceCreationPublishedOutcomeIsProven(
                      context,
                      expecting: created.expectation
                  )
            else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    .namespaceChanged
                )
            }
            let preparedActivation = try prepareWorkspaceCreationActivationIfNeeded(
                context,
                expecting: created.expectation
            )
            context = try resolveWorkspaceCreationAuthorities(context)
            guard workspaceCreationPublishedOutcomeIsProven(
                context,
                expecting: created.expectation
            ) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    .namespaceChanged
                )
            }
            if let preparedActivation {
                commitAnchoredFileSessionActivation(preparedActivation)
            }
        } catch {
            installWorkspaceCreationRecoveryContext(context)
            throw error
        }
        do {
            try releaseWorkspaceMutationRecovery(
                id: context.id,
                knownRecovery: .creation(context)
            )
        } catch {
            installWorkspaceCreationRecoveryContext(context)
            throw error
        }
    }

    private func finishIndeterminateWorkspaceCreation(
        _ indeterminate: WorkspaceIndeterminateItemCreation,
        recoveryIntent: WorkspaceCreationRecoveryContext
    ) throws {
        guard indeterminate.destination == recoveryIntent.destination else {
            throw WorkspaceMutationError.unexpectedDestination(
                indeterminate.destination.fileURL
            )
        }
        var context = recoveryIntent
        context.isPlanned = false
        context.expectedCreatedItem =
            indeterminate.createdExpectation ?? recoveryIntent.expectedCreatedItem
        context.reason = indeterminate.reason
        context.recoveryState = indeterminate.recoveryState
        context.recoveryExpectation =
            indeterminate.recoveryExpectation ?? recoveryIntent.recoveryExpectation
        context.publicationSource =
            indeterminate.publicationSource ?? recoveryIntent.publicationSource
        let reportedActualExpectation =
            indeterminate.actualPublishedExpectation ??
            recoveryIntent.actualPublishedExpectation
        context.actualPublishedExpectation =
            reportedActualExpectation == context.expectedCreatedItem
                ? nil
                : reportedActualExpectation
        captureMissingWorkspaceCreationAuthorityIfPossible(context: &context)
        do {
            try persistAndInstallWorkspaceMutationRecovery(.creation(context))
        } catch {
            installWorkspaceCreationRecoveryContext(context)
            throw error
        }
        refreshWorkspaceMutationReconciliationPrompt()
        throw WorkspaceMutationError.indeterminateOperation(
            indeterminate.destination.fileURL,
            indeterminate.reason
        )
    }

    private func prepareWorkspaceCreationActivationIfNeeded(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) throws -> PreparedAnchoredFileSessionActivation? {
        guard context.kind == .file,
              FileKind(url: context.destination.fileURL) != nil
        else {
            return nil
        }
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: fileStore,
            at: context.destination,
            expecting: expectation.identity
        )
        return try prepareAnchoredFileSessionActivation(
            file: preparedRead.result.file,
            at: context.destination,
            metadata: preparedRead.result.metadata,
            sha256Digest: preparedRead.result.sha256Digest,
            preparedImageAssetAuthority: preparedRead.preparedAuthority,
            excludingRecoveryID: context.id
        )
    }

    private func captureMissingWorkspaceCreationAuthorityIfPossible(
        context: inout WorkspaceCreationRecoveryContext
    ) {
        if let expectedCreatedItem = context.expectedCreatedItem,
           let publicationSource = context.publicationSource,
           context.createdItemBookmarkData == nil
        {
            do {
                let itemAuthority = try captureWorkspaceMutationItemBookmarkAuthority(
                    at: publicationSource.fileURL,
                    expecting: expectedCreatedItem
                )
                context.createdItemBookmarkData = itemAuthority.bookmarkData
                context.createdItemDisplayURL = itemAuthority.displayURL
                context.createdItemAuthorityLocation = itemAuthority.location
                context.publicationState = .prepared
            } catch {
                context.createdItemAuthorityLocation = nil
                context.publicationState = .unknown
            }
        } else if context.expectedCreatedItem != nil,
                  context.createdItemBookmarkData == nil
        {
            context.publicationState = .unknown
        }
    }

    private func persistWorkspaceCreationOutcomeOrInstallRecovery(
        _ context: WorkspaceCreationRecoveryContext
    ) throws {
        do {
            try persistWorkspaceMutationRecoveryIntent(.creation(context))
        } catch {
            installWorkspaceCreationRecoveryContext(context)
            throw error
        }
    }

    private func installWorkspaceCreationRecoveryContext(
        _ context: WorkspaceCreationRecoveryContext
    ) {
        workspaceMutationRecoveries[context.id] = .creation(context)
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func workspaceCreationPublishedOutcomeIsProven(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        workspaceCreationPublishedOutcomeIsProvenImpl(
            context,
            expecting: expectation
        ) && workspaceCreationPublishedOutcomeIsProvenImpl(
            context,
            expecting: expectation
        )
    }

    private func workspaceCreationPublishedOutcomeIsProvenImpl(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        guard context.expectedCreatedItem == expectation,
              context.actualPublishedExpectation == nil,
              context.publicationState == .prepared ||
              context.publicationState == .committed,
              context.recoveryState == .none,
              context.recoveryExpectation == nil
        else {
            return false
        }
        return workspaceCreationPublicationAuthorityIsProven(
            context,
            expecting: expectation
        )
    }

    private func workspaceCreationPublicationAuthorityIsProven(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        guard
            let publicationSource = context.publicationSource,
            let parentExpectation = context.parentExpectation,
            context.destinationParentAuthorityExpectation == parentExpectation,
            !context.destinationParentAuthorityIsUnresolved,
            let destinationAuthority = context.destinationParentAuthorityLocation,
            !context.createdItemAuthorityIsUnresolved,
            let itemAuthority = context.createdItemAuthorityLocation,
            workspaceCreationItemKindIsSupported(context.kind, expectation: expectation),
            workspaceCreationEntryAddress(
                destinationAuthority,
                matches: context.destination,
                parentExpectation: parentExpectation
            ),
            workspaceCreationEntryAddress(
                itemAuthority,
                matches: context.destination,
                parentExpectation: parentExpectation
            ),
            workspaceMutationExactExpectationState(
                at: context.destination,
                expecting: expectation,
                parentExpectation: parentExpectation
            ) == .expected,
            workspaceMutationExactExpectationState(
                at: itemAuthority,
                expecting: expectation,
                parentExpectation: parentExpectation
            ) == .expected,
            workspaceMutationExactExpectationState(
                at: publicationSource,
                expecting: expectation,
                parentExpectation:
                publicationSource.rootAuthority.directoryMutationExpectation
            ) == .missing
        else {
            return false
        }
        return true
    }

    private func workspaceCreationEntryAddress(
        _ authority: WorkspaceFileSystemLocation,
        matches logicalLocation: WorkspaceFileSystemLocation,
        parentExpectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        guard let authorityLeaf = exactRelativePathComponents(
            authority.relativePath
        ).last,
            let logicalLeaf = exactRelativePathComponents(
                logicalLocation.relativePath
            ).last,
            authorityLeaf.utf8.elementsEqual(logicalLeaf.utf8),
            (try? WorkspaceNoFollowItemInspector.inspectParent(of: authority)) ==
            parentExpectation,
            (try? WorkspaceNoFollowItemInspector.inspectParent(
                of: logicalLocation
            )) == parentExpectation
        else {
            return false
        }
        return true
    }

    private func workspaceCreationItemKindIsSupported(
        _ kind: WorkspaceCreationKind,
        expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        switch kind {
        case .file:
            expectation.kind == .regularFile
        case .folder:
            expectation.kind == .directory
        }
    }

    func installWorkspaceRelocationRecovery(
        plan: WorkspaceRelocationPlan,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        reason: WorkspaceItemMutationFailure,
        actualMovedExpectation: WorkspaceItemMutationExpectation? = nil
    ) {
        let sourceParentAuthority = try? SecurityScopedAccess.withAccess(
            to: plan.source.securityScopedURL
        ) {
            let standaloneSource = try WorkspaceFileSystemLocation(
                fileURL: plan.source.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneSource.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneSource.relativePath,
                expectingParent: sourceParentExpectation
            )
        }
        let destinationParentAuthority = try? SecurityScopedAccess.withAccess(
            to: plan.destination.securityScopedURL
        ) {
            let standaloneDestination = try WorkspaceFileSystemLocation(
                fileURL: plan.destination.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneDestination.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneDestination.relativePath,
                expectingParent: destinationParentExpectation
            )
        }
        let relocatedItemAuthority =
            (try? captureWorkspaceMutationItemBookmarkAuthority(
                at: plan.source.fileURL,
                expecting: plan.expectation
            )) ??
            (try? captureWorkspaceMutationItemBookmarkAuthority(
                at: plan.destination.fileURL,
                expecting: plan.expectation
            ))
        let hasDurableParentAuthorities = sourceParentAuthority != nil &&
            destinationParentAuthority != nil
        installWorkspaceMutationTextRecovery(
            for: plan.records,
            reason: .indeterminateMutation
        )
        let recoveryID = UUID()
        let remainingSessionIDs = Set(plan.records.map { ObjectIdentifier($0.session) })
        let context = WorkspaceRelocationRecoveryContext(
            id: recoveryID,
            source: plan.source,
            destination: plan.destination,
            expectation: plan.expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            sourceParentBookmarkData: sourceParentAuthority?.bookmarkData,
            sourceParentDisplayURL: sourceParentAuthority?.displayURL,
            sourceLeafName: sourceParentAuthority?.location.relativePath,
            sourceParentAuthorityExpectation: sourceParentExpectation,
            sourceParentAuthorityLocation: sourceParentAuthority?.location,
            destinationParentBookmarkData: destinationParentAuthority?.bookmarkData,
            destinationParentDisplayURL: destinationParentAuthority?.displayURL,
            destinationLeafName: destinationParentAuthority?.location.relativePath,
            destinationParentAuthorityExpectation: destinationParentExpectation,
            destinationParentAuthorityLocation: destinationParentAuthority?.location,
            relocatedItemBookmarkData: relocatedItemAuthority?.bookmarkData,
            relocatedItemDisplayURL: relocatedItemAuthority?.displayURL,
            relocatedItemAuthorityLocation: relocatedItemAuthority?.location,
            sessionCommitState: hasDurableParentAuthorities ? .pending : .unknown,
            reason: reason,
            actualMovedExpectation: actualMovedExpectation,
            records: plan.records,
            remainingSessionIDs: remainingSessionIDs
        )
        let recovery: WorkspaceMutationRecoveryContext = .relocation(context)
        do {
            try persistAndInstallWorkspaceMutationRecovery(recovery)
        } catch {
            workspaceMutationRecoveries[recoveryID] = recovery
            present(error, title: "Could Not Preserve Workspace Recovery")
        }
        quarantineWorkspaceMutationSessions(
            recoveryID: recoveryID,
            sessions: plan.records.map(\.session)
        )
        do {
            try persistWorkspaceMutationTextRecovery(for: plan.records.map(\.session))
        } catch {
            present(error, title: "Could Not Preserve Recovery Copy")
        }
    }

    func prepareWorkspaceRelocationRecoveryIntent(
        plan: WorkspaceRelocationPlan,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceRelocationRecoveryContext {
        let sourceParentAuthority = try SecurityScopedAccess.withAccess(
            to: plan.source.securityScopedURL
        ) {
            let standaloneSource = try WorkspaceFileSystemLocation(
                fileURL: plan.source.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneSource.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneSource.relativePath,
                expectingParent: sourceParentExpectation
            )
        }
        let relocatedItemAuthority = try captureWorkspaceMutationItemBookmarkAuthority(
            at: plan.source.fileURL,
            expecting: plan.expectation
        )
        let destinationParentAuthority = try SecurityScopedAccess.withAccess(
            to: plan.destination.securityScopedURL
        ) {
            let standaloneDestination = try WorkspaceFileSystemLocation(
                fileURL: plan.destination.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneDestination.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneDestination.relativePath,
                expectingParent: destinationParentExpectation
            )
        }
        installWorkspaceMutationTextRecovery(
            for: plan.records,
            reason: .indeterminateMutation
        )
        let context = WorkspaceRelocationRecoveryContext(
            id: UUID(),
            source: plan.source,
            destination: plan.destination,
            expectation: plan.expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            sourceParentBookmarkData: sourceParentAuthority.bookmarkData,
            sourceParentDisplayURL: sourceParentAuthority.displayURL,
            sourceLeafName: sourceParentAuthority.location.relativePath,
            sourceParentAuthorityExpectation: sourceParentExpectation,
            sourceParentAuthorityLocation: sourceParentAuthority.location,
            destinationParentBookmarkData: destinationParentAuthority.bookmarkData,
            destinationParentDisplayURL: destinationParentAuthority.displayURL,
            destinationLeafName: destinationParentAuthority.location.relativePath,
            destinationParentAuthorityExpectation: destinationParentExpectation,
            destinationParentAuthorityLocation: destinationParentAuthority.location,
            relocatedItemBookmarkData: relocatedItemAuthority.bookmarkData,
            relocatedItemDisplayURL: relocatedItemAuthority.displayURL,
            relocatedItemAuthorityLocation: relocatedItemAuthority.location,
            sessionCommitState: .pending,
            reason: .namespaceChanged,
            actualMovedExpectation: nil,
            records: plan.records,
            remainingSessionIDs: Set(plan.records.map { ObjectIdentifier($0.session) })
        )
        var operationPersistenceError: Error?
        do {
            try persistWorkspaceMutationRecoveryIntent(.relocation(context))
        } catch {
            operationPersistenceError = error
        }

        // The operation record bundles every current editor snapshot, but an upsert can fail
        // before or after writing. Independently try every standalone text record even after
        // one failure; if the operation journal failed, quarantine is only safe when all of
        // these snapshots are known durable. No edit can advance during this MainActor loop.
        var textPersistenceError: Error?
        var persistedSessions: Set<ObjectIdentifier> = []
        for session in plan.records.map(\.session)
            where persistedSessions.insert(ObjectIdentifier(session)).inserted
        {
            do {
                try persistWorkspaceMutationTextRecovery(for: session)
            } catch {
                textPersistenceError = textPersistenceError ?? error
            }
        }

        if let operationPersistenceError {
            workspaceMutationRecoveries[context.id] = .relocation(context)
            if textPersistenceError == nil {
                quarantineWorkspaceMutationSessions(
                    recoveryID: context.id,
                    sessions: plan.records.map(\.session)
                )
            } else if let persistenceError = textPersistenceError {
                refreshWorkspaceMutationReconciliationPrompt()
                present(
                    persistenceError,
                    title: "Could Not Preserve Recovery Copy"
                )
            }
            throw operationPersistenceError
        }
        if let textPersistenceError {
            present(textPersistenceError, title: "Could Not Preserve Recovery Copy")
        }
        return context
    }

    func installWorkspaceRelocationRecovery(
        _ installedContext: WorkspaceRelocationRecoveryContext,
        reason: WorkspaceItemMutationFailure,
        actualMovedExpectation: WorkspaceItemMutationExpectation?
    ) {
        var context = installedContext
        context.reason = reason
        context.actualMovedExpectation = actualMovedExpectation
        let recovery: WorkspaceMutationRecoveryContext = .relocation(context)
        do {
            try persistAndInstallWorkspaceMutationRecovery(recovery)
        } catch {
            workspaceMutationRecoveries[context.id] = recovery
            present(error, title: "Could Not Preserve Workspace Recovery")
        }
        quarantineWorkspaceMutationSessions(
            recoveryID: context.id,
            sessions: context.records.map(\.session)
        )
    }

    func installWorkspaceTrashRecovery(
        _ installedContext: WorkspaceTrashRecoveryContext,
        reason: WorkspaceItemMutationFailure,
        recoveryLocation: WorkspaceFileSystemLocation?,
        reportedTrashURL: URL?,
        cleanupState: WorkspaceTrashStagingCleanupState,
        actualStagedExpectation: WorkspaceItemMutationExpectation?
    ) {
        var context = installedContext
        context.reason = reason
        context.recoveryLocation = recoveryLocation
        context.reportedTrashURL = reportedTrashURL
        context.cleanupState = cleanupState
        context.actualStagedExpectation = actualStagedExpectation
        if let actualStagedExpectation {
            context.actualStagedEntryRecoveryLocation =
                actualStagedExpectation == context.expectation
                    ? nil
                    : context.source
        }
        context = workspaceTrashRecoveryContextCapturingReportedAuthorityIfPossible(
            context
        )
        let recovery: WorkspaceMutationRecoveryContext = .trash(context)
        do {
            try persistAndInstallWorkspaceMutationRecovery(recovery)
        } catch {
            workspaceMutationRecoveries[context.id] = recovery
            present(error, title: "Could Not Preserve Workspace Recovery")
        }
        quarantineWorkspaceMutationSessions(
            recoveryID: context.id,
            sessions: context.records.map(\.session)
        )
    }

    func installWorkspaceRelocationCleanupRecovery(
        _ context: WorkspaceRelocationRecoveryContext
    ) {
        let cleanup = WorkspaceRelocationRecoveryContext(
            id: context.id,
            source: context.source,
            destination: context.destination,
            expectation: context.expectation,
            sourceParentExpectation: context.sourceParentExpectation,
            destinationParentExpectation: context.destinationParentExpectation,
            sourceParentBookmarkData: context.sourceParentBookmarkData,
            sourceParentDisplayURL: context.sourceParentDisplayURL,
            sourceLeafName: context.sourceLeafName,
            sourceParentAuthorityExpectation: context.sourceParentAuthorityExpectation,
            sourceParentAuthorityLocation: context.sourceParentAuthorityLocation,
            destinationParentBookmarkData: context.destinationParentBookmarkData,
            destinationParentDisplayURL: context.destinationParentDisplayURL,
            destinationLeafName: context.destinationLeafName,
            destinationParentAuthorityExpectation:
            context.destinationParentAuthorityExpectation,
            destinationParentAuthorityLocation: context.destinationParentAuthorityLocation,
            relocatedItemBookmarkData: context.relocatedItemBookmarkData,
            relocatedItemDisplayURL: context.relocatedItemDisplayURL,
            relocatedItemAuthorityLocation: context.relocatedItemAuthorityLocation,
            sessionCommitState: context.sessionCommitState,
            reason: context.reason,
            actualMovedExpectation: context.actualMovedExpectation,
            records: context.records,
            remainingSessionIDs: context.remainingSessionIDs
        )
        do {
            try persistAndInstallWorkspaceMutationRecovery(.relocation(cleanup))
        } catch {
            workspaceMutationRecoveries[cleanup.id] = .relocation(cleanup)
            present(error, title: "Workspace Recovery Cleanup Needs Attention")
        }
        quarantineWorkspaceMutationSessions(
            recoveryID: cleanup.id,
            sessions: cleanup.records.map(\.session)
        )
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func installWorkspaceTrashCleanupRecovery(
        _ context: WorkspaceTrashRecoveryContext
    ) {
        var cleanup = WorkspaceTrashRecoveryContext(
            id: context.id,
            source: context.source,
            expectation: context.expectation,
            sourceParentExpectation: context.sourceParentExpectation,
            sourceParentBookmarkData: context.sourceParentBookmarkData,
            sourceParentDisplayURL: context.sourceParentDisplayURL,
            sourceLeafName: context.sourceLeafName,
            sourceParentAuthorityExpectation:
            context.sourceParentAuthorityExpectation,
            sourceParentAuthorityLocation: context.sourceParentAuthorityLocation,
            expectedItemBookmarkData: context.expectedItemBookmarkData,
            expectedItemDisplayURL: context.expectedItemDisplayURL,
            expectedItemAuthorityLocation: context.expectedItemAuthorityLocation,
            sessionCommitState: context.sessionCommitState,
            reason: context.reason,
            recoveryLocation: context.recoveryLocation,
            reportedTrashURL: context.reportedTrashURL,
            reportedTrashBookmarkData: context.reportedTrashBookmarkData,
            reportedTrashAuthorityLocation: context.reportedTrashAuthorityLocation,
            cleanupState: context.cleanupState,
            actualStagedExpectation: context.actualStagedExpectation,
            actualStagedEntryRecoveryLocation:
            context.actualStagedEntryRecoveryLocation,
            records: [],
            remainingSessionIDs: []
        )
        cleanup = workspaceTrashRecoveryContextCapturingReportedAuthorityIfPossible(
            cleanup
        )
        do {
            try persistAndInstallWorkspaceMutationRecovery(.trash(cleanup))
        } catch {
            workspaceMutationRecoveries[cleanup.id] = .trash(cleanup)
            present(error, title: "Workspace Recovery Cleanup Needs Attention")
        }
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func installWorkspaceTrashRecovery(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        records: [WorkspaceTrashSessionRecord],
        reason: WorkspaceItemMutationFailure,
        recoveryLocation: WorkspaceFileSystemLocation?,
        reportedTrashURL: URL?,
        cleanupState: WorkspaceTrashStagingCleanupState,
        actualStagedExpectation: WorkspaceItemMutationExpectation? = nil
    ) {
        installWorkspaceMutationTextRecovery(
            for: records,
            reason: .indeterminateMutation
        )
        let recoveryID = UUID()
        let remainingSessionIDs = Set(records.map { ObjectIdentifier($0.session) })
        var context = WorkspaceTrashRecoveryContext(
            id: recoveryID,
            source: source,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            sessionCommitState: .unknown,
            reason: reason,
            recoveryLocation: recoveryLocation,
            reportedTrashURL: reportedTrashURL,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: cleanupState,
            actualStagedExpectation: actualStagedExpectation,
            actualStagedEntryRecoveryLocation: actualStagedExpectation == nil ? nil : source,
            records: records,
            remainingSessionIDs: remainingSessionIDs
        )
        context = workspaceTrashRecoveryContextCapturingReportedAuthorityIfPossible(
            context
        )
        let recovery: WorkspaceMutationRecoveryContext = .trash(context)
        do {
            try persistAndInstallWorkspaceMutationRecovery(recovery)
        } catch {
            workspaceMutationRecoveries[recoveryID] = recovery
            present(error, title: "Could Not Preserve Workspace Recovery")
        }
        quarantineWorkspaceMutationSessions(
            recoveryID: recoveryID,
            sessions: records.map(\.session)
        )
        do {
            try persistWorkspaceMutationTextRecovery(for: records.map(\.session))
        } catch {
            present(error, title: "Could Not Preserve Recovery Copy")
        }
    }

    func refreshWorkspaceMutationReconciliationPrompt() {
        let sessionIdentity = ObjectIdentifier(currentDocument)
        let recovery: WorkspaceMutationRecoveryContext? =
            workspaceMutationRecoveryIDBySession[sessionIdentity]
                .flatMap { workspaceMutationRecoveries[$0] }
                ?? nextWorkspaceMutationRecovery()
        if let recovery {
            let secondaryAction: WorkspaceMutationRecoverySecondaryAction =
                if workspaceMutationRecoveryIDBySession[sessionIdentity] == recovery.id {
                    .keepEditorCopy
                } else if !recovery.remainingSessions.isEmpty {
                    .showEditorCopy
                } else {
                    .stopTracking
                }
            workspaceMutationReconciliationPrompt = WorkspaceMutationReconciliationPrompt(
                recoveryID: recovery.id,
                operation: recovery.operation,
                sourceURL: recovery.sourceURL,
                secondaryAction: secondaryAction
            )
            return
        }
        if let textRecovery = workspaceMutationTextRecoveryContexts[sessionIdentity],
           textRecovery.requiresExplicitStopTracking
        {
            workspaceMutationReconciliationPrompt = WorkspaceMutationReconciliationPrompt(
                recoveryID: textRecovery.recoveryID,
                operation: .textRecovery,
                sourceURL: textRecovery.originalURL,
                secondaryAction: .stopTracking
            )
            return
        }
        if isActionableWorkspaceMutationTextRecoverySession(currentDocument) {
            workspaceMutationReconciliationPrompt = nil
            return
        }
        guard let textRecoverySession = nextWorkspaceMutationTextRecoverySession(),
              let textRecovery = workspaceMutationTextRecoveryContexts[
                  ObjectIdentifier(textRecoverySession)
              ]
        else {
            workspaceMutationReconciliationPrompt = nil
            return
        }
        workspaceMutationReconciliationPrompt = WorkspaceMutationReconciliationPrompt(
            recoveryID: textRecovery.recoveryID,
            operation: .textRecovery,
            sourceURL: textRecovery.originalURL,
            secondaryAction: .showEditorCopy
        )
    }

    func reconcileCurrentWorkspaceMutationRecovery() {
        guard let recoveryID =
            workspaceMutationRecoveryIDBySession[ObjectIdentifier(currentDocument)]
                ?? workspaceMutationReconciliationPrompt?.recoveryID
                ?? nextWorkspaceMutationRecovery()?.id
        else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        guard let recovery = workspaceMutationRecoveries[recoveryID] else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        if let pendingSession = recovery.remainingSessions.first(where: {
            hasPendingEditorSource(for: $0)
        }) {
            present(
                AppStateError.pendingEditorSource(
                    sessionStateURL(for: pendingSession)
                        ?? pendingSession.fileURL
                        ?? recovery.sourceURL
                ),
                title: "Could Not Reconcile Workspace Item"
            )
            return
        }

        do {
            try beginWorkspaceNamespaceMutation(
                recovery.remainingSessions,
                allowingExistingRecovery: true
            )
        } catch {
            present(error, title: "Could Not Reconcile Workspace Item")
            return
        }

        let completion: WorkspaceMutationReconciliationCompletion
        do {
            completion = try reconcileWorkspaceMutationRecovery(id: recoveryID)
        } catch {
            endWorkspaceNamespaceMutation(recovery.remainingSessions)
            drainWorkspaceMutationRefreshIfNeeded()
            present(error, title: "Could Not Reconcile Workspace Item")
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        endWorkspaceNamespaceMutation(recovery.remainingSessions)
        drainWorkspaceMutationRefreshIfNeeded()

        switch completion {
        case .creation:
            break
        case let .relocation(records):
            resumeWorkspaceRelocationWork(records)
            inspectReconciledWorkspaceSessions(records.map(\.session))
        case let .trashRestored(records):
            resumeWorkspaceTrashWork(records)
            inspectReconciledWorkspaceSessions(records.map(\.session))
        case let .trashFinished(records):
            resumeWorkspaceTrashWork(records)
        }
        promoteNextWorkspaceMutationRecoverySessionIfNeeded()
    }

    func performWorkspaceMutationRecoverySecondaryAction() {
        guard let prompt = workspaceMutationReconciliationPrompt else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        if prompt.operation == .textRecovery {
            guard let session = workspaceMutationTextRecoverySessions[prompt.recoveryID] else {
                refreshWorkspaceMutationReconciliationPrompt()
                return
            }
            switch prompt.secondaryAction {
            case .stopTracking:
                stopTrackingWorkspaceMutationTextRecovery(for: session)
            case .keepEditorCopy, .showEditorCopy:
                setCurrentDocument(session)
                restoreRecoveryPrompt(for: session)
            }
            return
        }
        guard let recovery = workspaceMutationRecoveries[prompt.recoveryID] else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        switch prompt.secondaryAction {
        case .keepEditorCopy:
            keepCurrentWorkspaceMutationEditorCopy()
        case .showEditorCopy:
            guard let session = recovery.remainingSessions.first else {
                refreshWorkspaceMutationReconciliationPrompt()
                return
            }
            setCurrentDocument(session)
            restoreRecoveryPrompt(for: session)
        case .stopTracking:
            guard recovery.remainingSessions.isEmpty else {
                refreshWorkspaceMutationReconciliationPrompt()
                return
            }
            do {
                try releaseWorkspaceMutationRecovery(id: recovery.id)
            } catch {
                present(error, title: "Could Not Stop Tracking Workspace Recovery")
                return
            }
            drainWorkspaceMutationRefreshIfNeeded()
            promoteNextWorkspaceMutationRecoverySessionIfNeeded()
        }
    }

    func keepCurrentWorkspaceMutationEditorCopy() {
        let session = currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        guard workspaceMutationRecoveryIDBySession[sessionIdentity] != nil,
              let oldURL = sessionStateURL(for: session)
        else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }

        do {
            try persistWorkspaceMutationTextRecovery(for: session)
            try releaseWorkspaceMutationRecoverySession(session)
        } catch {
            present(error, title: "Could Not Preserve Recovery Copy")
            return
        }
        discardEditorImageAssetDocumentAuthority(for: session)
        markSessionDetachedFromMissingFile(session, url: oldURL)
        refreshWorkspaceMutationReconciliationPrompt()
        restoreRecoveryPrompt(for: session)
    }

    func releaseWorkspaceMutationRecoverySession(_ session: DocumentSession) throws {
        let sessionIdentity = ObjectIdentifier(session)
        guard let recoveryID = workspaceMutationRecoveryIDBySession[sessionIdentity] else {
            indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
            return
        }

        guard let recovery = workspaceMutationRecoveries[recoveryID] else { return }
        let updatedRecovery: WorkspaceMutationRecoveryContext
        switch recovery {
        case .creation:
            return
        case var .relocation(context):
            context.remainingSessionIDs.remove(sessionIdentity)
            updatedRecovery = .relocation(context)
        case var .trash(context):
            context.remainingSessionIDs.remove(sessionIdentity)
            updatedRecovery = .trash(context)
        case .unavailable:
            return
        }
        try persistWorkspaceMutationRecoveryUpdate(updatedRecovery)
        workspaceMutationRecoveryIDBySession[sessionIdentity] = nil
        indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
    }

    func promoteNextWorkspaceMutationRecoverySessionIfNeeded() {
        guard workspaceMutationRecoveryIDBySession[ObjectIdentifier(currentDocument)] == nil
        else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        if isActionableWorkspaceMutationTextRecoverySession(currentDocument) {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }
        if let recovery = nextWorkspaceMutationRecovery() {
            if let nextSession = recovery.remainingSessions.first {
                setCurrentDocument(nextSession)
                restoreRecoveryPrompt(for: nextSession)
            } else {
                refreshWorkspaceMutationReconciliationPrompt()
            }
            return
        }
        if let nextSession = nextWorkspaceMutationTextRecoverySession() {
            setCurrentDocument(nextSession)
            restoreRecoveryPrompt(for: nextSession)
            return
        }
        workspaceMutationReconciliationPrompt = nil
        restoreWorkspaceMutationTextRecoveryIfNeeded()
    }

    func isWorkspaceMutationRecoveryCandidate(
        _ location: WorkspaceFileSystemLocation,
        excludingRecoveryID: UUID? = nil
    ) -> Bool {
        workspaceMutationRecoveries.values.contains { recovery in
            guard recovery.id != excludingRecoveryID else { return false }
            if case .unavailable = recovery {
                return true
            }
            return recovery.retainedCandidateLocations.contains { candidate in
                guard let candidateRelativePath = try?
                    candidate.rootAuthority.relativePath(
                        forFileURL: location.fileURL
                    )
                else {
                    return false
                }
                let parentIsCaseSensitive =
                    (try? WorkspaceNoFollowItemInspector.parentIsCaseSensitive(
                        of: candidate
                    )) ??
                    (try? WorkspaceNoFollowItemInspector.rootIsCaseSensitive(
                        of: candidate
                    )) ?? false
                let requestedKey = workspaceSaveCopyAliasKey(
                    candidateRelativePath,
                    parentIsCaseSensitive: parentIsCaseSensitive
                )
                return workspaceMutationDestination(
                    requestedKey,
                    owns: candidate.relativePath,
                    parentIsCaseSensitive: parentIsCaseSensitive
                )
            }
        }
    }
}

@MainActor
extension AppState {
    func quarantineWorkspaceMutationSessions(
        recoveryID: UUID,
        sessions: [DocumentSession]
    ) {
        for session in sessions {
            let sessionIdentity = ObjectIdentifier(session)
            workspaceMutationRecoveryIDBySession[sessionIdentity] = recoveryID
            indeterminateWorkspaceMutationSessions.insert(sessionIdentity)
            cancelAutosave(for: session)
            externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            supersedeExternalResolutionRead(for: session)
            discardEditorImageAssetDocumentAuthority(for: session)
        }
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func reconcileWorkspaceMutationRecovery(
        id recoveryID: UUID
    ) throws -> WorkspaceMutationReconciliationCompletion {
        guard let recovery = workspaceMutationRecoveries[recoveryID] else {
            throw WorkspaceMutationError.indeterminateOperation(
                URL(fileURLWithPath: "/"),
                .namespaceChanged
            )
        }
        switch recovery {
        case let .creation(context):
            return try reconcileWorkspaceCreation(context)
        case let .relocation(context):
            return try reconcileWorkspaceRelocation(context)
        case let .trash(context):
            return try reconcileWorkspaceTrash(context)
        case let .unavailable(context):
            let restored = try restoreWorkspaceMutationOperationRecovery(
                context.record
            )
            workspaceMutationRecoveries[recoveryID] = restored
            return try reconcileWorkspaceMutationRecovery(id: recoveryID)
        }
    }

    func reconcileWorkspaceCreation(
        _ installedContext: WorkspaceCreationRecoveryContext
    ) throws -> WorkspaceMutationReconciliationCompletion {
        var context = try resolveWorkspaceCreationAuthorities(installedContext)
        switch context.publicationState {
        case .unknown:
            throw WorkspaceMutationError.indeterminateOperation(
                context.destination.fileURL,
                context.reason
            )

        case .planned:
            guard workspaceCreationPlannedIntentIsEmpty(context) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    context.reason
                )
            }
            try releaseWorkspaceMutationRecovery(
                id: context.id,
                knownRecovery: .creation(context)
            )
            refreshWorkspaceAfterFileSystemChange()
            return .creation

        case .prepared:
            guard let expectation = context.expectedCreatedItem,
                  workspaceCreationPreparedPublicationIsProven(
                      context,
                      expecting: expectation
                  )
            else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    context.reason
                )
            }
            context.isPlanned = false
            context.recoveryState = .none
            context.recoveryExpectation = nil
            context.publicationState = .committed
            try persistWorkspaceMutationRecoveryUpdate(.creation(context))

        case .committed:
            break
        }

        context = try resolveWorkspaceCreationAuthorities(context)
        guard context.publicationState == .committed,
              let destinationExpectation = context.expectedCreatedItem,
              workspaceCreationPublishedOutcomeIsProven(
                  context,
                  expecting: destinationExpectation
              )
        else {
            throw WorkspaceMutationError.indeterminateOperation(
                context.destination.fileURL,
                context.reason
            )
        }
        let preparedActivation: PreparedAnchoredFileSessionActivation?
        do {
            preparedActivation = try prepareWorkspaceCreationActivationIfNeeded(
                context,
                expecting: destinationExpectation
            )
        } catch {
            workspaceMutationRecoveries[context.id] = .creation(context)
            refreshWorkspaceMutationReconciliationPrompt()
            throw error
        }
        context = try resolveWorkspaceCreationAuthorities(context)
        guard workspaceCreationPublishedOutcomeIsProven(
            context,
            expecting: destinationExpectation
        ) else {
            throw WorkspaceMutationError.indeterminateOperation(
                context.destination.fileURL,
                context.reason
            )
        }
        if let preparedActivation {
            commitAnchoredFileSessionActivation(preparedActivation)
        }
        try releaseWorkspaceMutationRecovery(
            id: context.id,
            knownRecovery: .creation(context)
        )
        refreshWorkspaceMutationReconciliationPrompt()
        refreshWorkspaceAfterFileSystemChange()
        return .creation
    }

    func workspaceCreationPlannedIntentIsEmpty(
        _ context: WorkspaceCreationRecoveryContext
    ) -> Bool {
        workspaceCreationPlannedIntentIsEmptyImpl(context) &&
            workspaceCreationPlannedIntentIsEmptyImpl(context)
    }

    private func workspaceCreationPlannedIntentIsEmptyImpl(
        _ context: WorkspaceCreationRecoveryContext
    ) -> Bool {
        guard context.publicationState == .planned,
              context.expectedCreatedItem == nil,
              context.createdItemBookmarkData == nil,
              context.recoveryState == .none,
              context.recoveryExpectation == nil,
              context.actualPublishedExpectation == nil,
              let parentExpectation = context.parentExpectation,
              context.destinationParentAuthorityExpectation == parentExpectation,
              !context.destinationParentAuthorityIsUnresolved,
              let destinationAuthority = context.destinationParentAuthorityLocation,
              workspaceCreationEntryAddress(
                  destinationAuthority,
                  matches: context.destination,
                  parentExpectation: parentExpectation
              )
        else {
            return false
        }
        return [
            context.destination,
            context.publicationSource,
            context.recoveryState.location,
        ].compactMap { $0 }.allSatisfy(workspaceCreationCandidateIsMissing)
    }

    func workspaceCreationPreparedPublicationIsProven(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        workspaceCreationPreparedPublicationIsProvenImpl(
            context,
            expecting: expectation
        ) && workspaceCreationPreparedPublicationIsProvenImpl(
            context,
            expecting: expectation
        )
    }

    private func workspaceCreationPreparedPublicationIsProvenImpl(
        _ context: WorkspaceCreationRecoveryContext,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        guard context.publicationState == .prepared,
              context.expectedCreatedItem == expectation,
              context.actualPublishedExpectation == nil
        else {
            return false
        }
        return workspaceCreationPublicationAuthorityIsProven(
            context,
            expecting: expectation
        )
    }

    func workspaceCreationCandidateIsMissing(
        _ location: WorkspaceFileSystemLocation
    ) -> Bool {
        do {
            _ = try WorkspaceNoFollowItemInspector.inspect(at: location)
            return false
        } catch WorkspaceAnchoredFileSystemError.missing {
            return true
        } catch {
            return false
        }
    }

    func reconcileWorkspaceRelocation(
        _ installedContext: WorkspaceRelocationRecoveryContext
    ) throws -> WorkspaceMutationReconciliationCompletion {
        let recoveredContext = try restoreEscapedRelocationEntryIfNeeded(installedContext)
        let context = try reconcileUnexpectedRelocationEntryIfNeeded(recoveredContext)
        let records = context.records.filter {
            context.remainingSessionIDs.contains(ObjectIdentifier($0.session))
        }

        if context.sessionCommitState == .pending,
           workspaceRelocationPhaseTargetIsProven(context)
        {
            let preparedAuthorities = try prepareRetainedImageAuthoritiesForRelocationRollback(
                records
            )
            guard workspaceRelocationPhaseTargetIsProven(context) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.source.fileURL,
                    context.reason
                )
            }
            for record in records {
                let sessionIdentity = ObjectIdentifier(record.session)
                if let prepared = preparedAuthorities[sessionIdentity] {
                    editorImageAssetDocumentAuthorities[sessionIdentity] =
                        RetainedEditorImageAssetDocumentAuthority(prepared)
                }
            }
            try releaseWorkspaceMutationRecovery(id: context.id)
            clearResolvedWorkspaceMutationTextRecovery(for: records.map(\.session))
            return .relocation(records)
        }

        if context.sessionCommitState == .committed,
           workspaceRelocationPhaseTargetIsProven(context)
        {
            let preparedAuthorities = try
                prepareRetainedImageAuthoritiesForCommittedRelocation(
                    records
                )
            guard workspaceRelocationPhaseTargetIsProven(context) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.destination.fileURL,
                    context.reason
                )
            }
            for record in records {
                let sessionIdentity = ObjectIdentifier(record.session)
                if let prepared = preparedAuthorities[sessionIdentity] {
                    editorImageAssetDocumentAuthorities[sessionIdentity] =
                        RetainedEditorImageAssetDocumentAuthority(prepared)
                }
            }
            try releaseWorkspaceMutationRecovery(id: context.id)
            clearResolvedWorkspaceMutationTextRecovery(for: records.map(\.session))
            return .relocation(records)
        }

        throw WorkspaceMutationError.indeterminateOperation(
            context.destination.fileURL,
            context.reason
        )
    }

    func prepareRetainedImageAuthoritiesForCommittedRelocation(
        _ records: [WorkspaceSessionRelocationRecord]
    ) throws -> [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] {
        var prepared: [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] = [:]
        for record in records {
            guard let binding = anchoredSessionFileBinding(for: record.session),
                  binding.identity == record.identity,
                  exactFileURLSpellingMatches(binding.location.fileURL, record.newURL)
            else {
                throw WorkspaceMutationError.unprovenSessionAuthority(record.newURL)
            }
            prepared[ObjectIdentifier(record.session)] =
                try prepareEditorImageAssetDocumentAuthority(
                    at: record.newLocation,
                    expecting: record.identity
                )
        }
        return prepared
    }

    func reconcileWorkspaceTrash(
        _ installedContext: WorkspaceTrashRecoveryContext
    ) throws -> WorkspaceMutationReconciliationCompletion {
        let resolvedContext = try resolveWorkspaceTrashAuthorities(installedContext)
        let context = try reconcileUnexpectedTrashStagingEntryIfNeeded(resolvedContext)
        let records = context.records.filter {
            context.remainingSessionIDs.contains(ObjectIdentifier($0.session))
        }

        if workspaceTrashSourceIsSoleExpectedLocation(context) {
            let preparedAuthorities = try prepareRetainedImageAuthoritiesForTrashRollback(
                records
            )
            guard workspaceTrashSourceIsSoleExpectedLocation(context) else {
                throw WorkspaceMutationError.indeterminateOperation(
                    context.source.fileURL,
                    context.reason
                )
            }
            for record in records {
                let sessionIdentity = ObjectIdentifier(record.session)
                if let prepared = preparedAuthorities[sessionIdentity] {
                    editorImageAssetDocumentAuthorities[sessionIdentity] =
                        RetainedEditorImageAssetDocumentAuthority(prepared)
                }
            }
            try releaseWorkspaceMutationRecovery(id: context.id)
            clearResolvedWorkspaceMutationTextRecovery(for: records.map(\.session))
            return .trashRestored(records)
        }

        if try restoreWorkspaceTrashRecoveryLocationIfPossible(context) {
            return try reconcileWorkspaceTrash(context)
        }

        if provenReportedTrashLocation(context) != nil {
            try releaseWorkspaceMutationRecovery(id: context.id)
            finishWorkspaceTrash(records)
            return .trashFinished(records)
        }

        throw WorkspaceMutationError.indeterminateOperation(
            context.source.fileURL,
            context.reason
        )
    }

    func releaseWorkspaceMutationRecovery(
        id recoveryID: UUID,
        knownRecovery: WorkspaceMutationRecoveryContext? = nil
    ) throws {
        guard let recovery = workspaceMutationRecoveries[recoveryID] ?? knownRecovery else {
            return
        }
        do {
            try ensureWorkspaceMutationRecoveryTextIsDurable(recovery)
            try removePersistedWorkspaceMutationRecovery(id: recoveryID)
        } catch {
            let removalError = error
            do {
                try persistAndInstallWorkspaceMutationRecovery(recovery)
            } catch {
                workspaceMutationRecoveries[recoveryID] = recovery
            }
            refreshWorkspaceMutationReconciliationPrompt()
            throw removalError
        }
        clearInstalledWorkspaceMutationRecovery(
            id: recoveryID,
            knownRecovery: recovery
        )
    }

    /// A terminal proof helper may install its freshly resolved recovery context even on the
    /// ordinary success path. Durable journal removal and runtime release are one logical
    /// transition; leaving that installed value behind would permanently fence quit and every
    /// later namespace mutation despite the filesystem transaction having completed.
    func clearInstalledWorkspaceMutationRecovery(
        id recoveryID: UUID,
        knownRecovery: WorkspaceMutationRecoveryContext? = nil
    ) {
        let recovery = workspaceMutationRecoveries[recoveryID] ?? knownRecovery
        workspaceMutationRecoveries[recoveryID] = nil
        for sessionIdentity in recovery?.remainingSessionIDs ?? [] {
            if workspaceMutationRecoveryIDBySession[sessionIdentity] == recoveryID {
                workspaceMutationRecoveryIDBySession[sessionIdentity] = nil
            }
            indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
        }
        refreshWorkspaceMutationReconciliationPrompt()
    }

    func nextWorkspaceMutationTextRecoverySession() -> DocumentSession? {
        workspaceMutationTextRecoverySessions.values
            .filter { session in
                guard session !== currentDocument,
                      workspaceMutationTextRecoveryContexts[ObjectIdentifier(session)] != nil
                else { return false }
                return isActionableWorkspaceMutationTextRecoverySession(session)
            }
            .sorted {
                let firstURL = workspaceMutationTextRecoveryContexts[ObjectIdentifier($0)]?
                    .originalURL.absoluteString ?? ""
                let secondURL = workspaceMutationTextRecoveryContexts[ObjectIdentifier($1)]?
                    .originalURL.absoluteString ?? ""
                return firstURL < secondURL
            }
            .first
    }

    func isActionableWorkspaceMutationTextRecoverySession(
        _ session: DocumentSession
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity],
              let stateURL = sessionStateURL(for: session)
        else {
            return false
        }
        if context.requiresExplicitStopTracking {
            return true
        }
        if detachedSessionURLs.contains(where: {
            exactFileURLSpellingMatches($0, stateURL)
        }) {
            return true
        }
        if case .some(.unavailable) =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        {
            return true
        }
        return false
    }

    func prepareRetainedImageAuthoritiesForRelocationRollback(
        _ records: [WorkspaceSessionRelocationRecord]
    ) throws -> [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] {
        var prepared: [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] = [:]
        for record in records {
            guard let binding = anchoredSessionFileBinding(for: record.session),
                  binding.identity == record.identity,
                  exactFileURLSpellingMatches(binding.location.fileURL, record.oldURL)
            else {
                throw WorkspaceMutationError.unprovenSessionAuthority(record.oldURL)
            }
            prepared[ObjectIdentifier(record.session)] =
                try prepareEditorImageAssetDocumentAuthority(
                    at: binding.location,
                    expecting: record.identity
                )
        }
        return prepared
    }

    func prepareRetainedImageAuthoritiesForTrashRollback(
        _ records: [WorkspaceTrashSessionRecord]
    ) throws -> [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] {
        var prepared: [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] = [:]
        for record in records {
            prepared[ObjectIdentifier(record.session)] =
                try prepareEditorImageAssetDocumentAuthority(
                    at: record.oldLocation,
                    expecting: record.identity
                )
        }
        return prepared
    }

    func inspectReconciledWorkspaceSessions(_ sessions: [DocumentSession]) {
        for session in sessions {
            handleExternalChange(for: session, advancingDiskEvent: false)
        }
        restoreRecoveryPrompt(for: currentDocument)
    }
}
