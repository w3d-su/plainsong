// swiftlint:disable file_length
import Foundation
import MarkdownCore
import WorkspaceKit

struct WorkspaceMutationBookmarkResolution {
    let fileURL: URL
    let isStale: Bool
}

protocol WorkspaceMutationBookmarkAccessing {
    func makeBookmark(for fileURL: URL) throws -> Data
    func resolveBookmark(
        _ bookmarkData: Data
    ) throws -> WorkspaceMutationBookmarkResolution
}

struct ProductionMutationBookmarkAccess: WorkspaceMutationBookmarkAccessing {
    func makeBookmark(for fileURL: URL) throws -> Data {
        try SecurityScopedAccess.withAccess(to: fileURL) {
            try fileURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    func resolveBookmark(
        _ bookmarkData: Data
    ) throws -> WorkspaceMutationBookmarkResolution {
        var isStale = false
        let fileURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return WorkspaceMutationBookmarkResolution(
            fileURL: fileURL,
            isStale: isStale
        )
    }
}

// Keep the existing AppState injection surface source-compatible while the bookmark service is
// shared by Trash and relocation recovery.
typealias ReportedTrashBookmarkResolution = WorkspaceMutationBookmarkResolution
typealias ReportedTrashBookmarkAccessing = WorkspaceMutationBookmarkAccessing
typealias ProductionReportedTrashBookmarkAccess = ProductionMutationBookmarkAccess

enum WorkspaceMutationOperationRecoveryError: LocalizedError {
    case invalidRecord(URL)
    case rootAuthorityChanged(URL)
    case rootBookmarkUnavailable(URL)
    case textRecoveryUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidRecord(url):
            "The saved recovery information for \(url.lastPathComponent) is invalid."
        case let .rootAuthorityChanged(url):
            "The workspace containing \(url.lastPathComponent) no longer matches the saved recovery authority."
        case let .rootBookmarkUnavailable(url):
            "The workspace containing \(url.lastPathComponent) could not be reopened from its saved recovery bookmark."
        case let .textRecoveryUnavailable(url):
            "The newest editor recovery for \(url.lastPathComponent) could not be loaded safely."
        }
    }
}

@MainActor
extension AppState {
    var workspaceMutationBookmarkAccess: any WorkspaceMutationBookmarkAccessing {
        reportedTrashBookmarkAccess
    }

    func restoreWorkspaceMutationOperationRecoveryIfNeeded() {
        guard !pendingWorkspaceMutationOperationRecoveryRecords.isEmpty else { return }
        let records = pendingWorkspaceMutationOperationRecoveryRecords
        pendingWorkspaceMutationOperationRecoveryRecords.removeAll()
        mergeAndPromoteBundledWorkspaceMutationTextRecoveryRecords(from: records)

        for record in records {
            workspaceMutationOperationRecoveryRecords[record.id] = record
            do {
                workspaceMutationRecoveries[record.id] =
                    try restoreWorkspaceMutationOperationRecovery(record)
            } catch let error as WorkspaceMutationOperationRecoveryError {
                workspaceMutationRecoveries[record.id] = .unavailable(.init(
                    record: record,
                    failure: error
                ))
            } catch {
                workspaceMutationRecoveries[record.id] = .unavailable(.init(
                    record: record,
                    failure: .rootBookmarkUnavailable(record.sourceURL)
                ))
            }
        }
        refreshWorkspaceMutationReconciliationPrompt()
    }

    // swiftlint:disable:next function_body_length
    func restoreWorkspaceMutationOperationRecovery(
        _ installedRecord: WorkspaceMutationOperationRecoveryRecord
    ) throws -> WorkspaceMutationRecoveryContext {
        var isStale = false
        let rootURL: URL
        do {
            rootURL = try URL(
                resolvingBookmarkData: installedRecord.rootBookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw WorkspaceMutationOperationRecoveryError.rootBookmarkUnavailable(
                installedRecord.sourceURL
            )
        }

        let authority: WorkspaceFileSystemRootAuthority
        do {
            authority = try WorkspaceFileSystemRootAuthority(
                rootURL: rootURL,
                securityScopedURL: rootURL
            )
        } catch {
            throw WorkspaceMutationOperationRecoveryError.rootBookmarkUnavailable(
                installedRecord.sourceURL
            )
        }
        guard authority.directoryMutationExpectation ==
            installedRecord.rootExpectation.runtimeValue
        else {
            throw WorkspaceMutationOperationRecoveryError.rootAuthorityChanged(
                installedRecord.sourceURL
            )
        }

        var record = installedRecord
        var shouldPersistRecordUpdate = false
        if isStale {
            let refreshedBookmark = try SecurityScopedAccess.withAccess(to: rootURL) {
                try rootURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            record = installedRecord.replacingRootBookmark(
                refreshedBookmark,
                rootDisplayURL: authority.canonicalRootURL
            )
            shouldPersistRecordUpdate = true
        }

        let creationParentRestoration =
            recordRestoringCreationDestinationParent(record)
        record = creationParentRestoration.record
        let creationItemRestoration = recordRestoringCreationCreatedItem(record)
        record = creationItemRestoration.record
        let reportedTrashRestoration = recordRestoringReportedTrashAuthority(record)
        record = reportedTrashRestoration.record
        let trashExpectedItemRestoration =
            recordRestoringTrashExpectedItemAuthority(record)
        record = trashExpectedItemRestoration.record
        let trashSourceParentRestoration =
            recordRestoringTrashSourceParent(record)
        record = trashSourceParentRestoration.record
        let sourceParentRestoration = recordRestoringRelocationSourceParent(record)
        record = sourceParentRestoration.record
        let destinationParentRestoration =
            recordRestoringRelocationDestinationParent(record)
        record = destinationParentRestoration.record
        let itemRestoration = recordRestoringRelocatedItem(record)
        record = itemRestoration.record
        shouldPersistRecordUpdate = shouldPersistRecordUpdate ||
            creationParentRestoration.didUpdate ||
            creationItemRestoration.didUpdate ||
            reportedTrashRestoration.didUpdate ||
            trashExpectedItemRestoration.didUpdate ||
            trashSourceParentRestoration.didUpdate ||
            sourceParentRestoration.didUpdate ||
            destinationParentRestoration.didUpdate ||
            itemRestoration.didUpdate
        if shouldPersistRecordUpdate {
            try workspaceMutationOperationRecoveryStore.upsert(record)
        }
        workspaceMutationOperationRecoveryRecords[record.id] = record
        return try workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: authority,
            restoredAuthorities: RestoredRecoveryAuthorities(
                creationDestinationParentLocation:
                creationParentRestoration.authority.location,
                creationCreatedItemLocation:
                creationItemRestoration.authority.location,
                sourceParentLocation: sourceParentRestoration.authority.location,
                destinationParentLocation:
                destinationParentRestoration.authority.location,
                relocatedItemLocation: itemRestoration.authority.location,
                trashExpectedItemLocation:
                trashExpectedItemRestoration.authority.location,
                trashSourceParentLocation:
                trashSourceParentRestoration.authority.location,
                reportedTrashLocation: reportedTrashRestoration.authority.location,
                reportedTrashDisplayURL: reportedTrashRestoration.authority.displayURL
            )
        )
    }

    func recordRestoringCreationDestinationParent(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredCreationDestinationParentAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .creation(creation) = record.payload,
              let leafName = creation.destinationLeafName,
              let parentExpectation = creation.destinationLocatorParentExpectation
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .creation(creation.replacingDestinationParentLocator(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL,
                    leafName: leafName,
                    parentExpectation: parentExpectation
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringCreationCreatedItem(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredCreationCreatedItemAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .creation(creation) = record.payload
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .creation(creation.replacingCreatedItemAuthority(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringReportedTrashAuthority(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredReportedTrashAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .trash(trash) = record.payload
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .trash(trash.replacingReportedTrashAuthority(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringTrashExpectedItemAuthority(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredTrashExpectedItemAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .trash(trash) = record.payload
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .trash(trash.replacingExpectedItemAuthority(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringTrashSourceParent(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredTrashSourceParentAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .trash(trash) = record.payload,
              let leafName = trash.sourceLeafName
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .trash(trash.replacingSourceParentLocator(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL,
                    leafName: leafName,
                    parentExpectation: trash.sourceLocatorParentExpectation
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringRelocationSourceParent(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredRelocationSourceParentAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .relocation(relocation) = record.payload,
              let leafName = relocation.sourceLeafName
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .relocation(relocation.replacingSourceParentLocator(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL,
                    leafName: leafName,
                    parentExpectation: relocation.sourceLocatorParentExpectation
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringRelocationDestinationParent(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredRelocationDestinationParentAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .relocation(relocation) = record.payload,
              let leafName = relocation.destinationLeafName
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .relocation(relocation.replacingDestinationParentLocator(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL,
                    leafName: leafName,
                    parentExpectation:
                    relocation.destinationLocatorParentExpectation
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func recordRestoringRelocatedItem(
        _ record: WorkspaceMutationOperationRecoveryRecord
    ) -> (
        record: WorkspaceMutationOperationRecoveryRecord,
        authority: RestoredMutationBookmarkAuthority,
        didUpdate: Bool
    ) {
        let authority = restoredRelocationItemAuthority(from: record)
        guard let bookmarkData = authority.refreshedBookmarkData,
              let displayURL = authority.displayURL,
              case let .relocation(relocation) = record.payload
        else {
            return (record, authority, false)
        }
        return (
            record.replacingPayload(
                .relocation(relocation.replacingRelocatedItemAuthority(
                    bookmarkData: bookmarkData,
                    displayURL: displayURL
                )),
                textRecoveryRecords: record.textRecoveryRecords
            ),
            authority,
            true
        )
    }

    func persistAndInstallWorkspaceMutationRecovery(
        _ recovery: WorkspaceMutationRecoveryContext
    ) throws {
        try validateWorkspaceMutationOperationRecoveryStoreLoaded(
            at: recovery.sourceURL
        )
        let record = try workspaceMutationOperationRecoveryRecord(for: recovery)
        workspaceMutationOperationRecoveryRecords[recovery.id] = record
        try workspaceMutationOperationRecoveryStore.upsert(record)
        workspaceMutationRecoveries[recovery.id] = recovery
    }

    func persistWorkspaceMutationRecoveryIntent(
        _ recovery: WorkspaceMutationRecoveryContext
    ) throws {
        try validateWorkspaceMutationOperationRecoveryStoreLoaded(
            at: recovery.sourceURL
        )
        let record = try workspaceMutationOperationRecoveryRecord(for: recovery)
        workspaceMutationOperationRecoveryRecords[recovery.id] = record
        try workspaceMutationOperationRecoveryStore.upsert(record)
    }

    func persistWorkspaceMutationRecoveryUpdate(
        _ recovery: WorkspaceMutationRecoveryContext
    ) throws {
        try persistAndInstallWorkspaceMutationRecovery(recovery)
    }

    func removePersistedWorkspaceMutationRecovery(id: UUID) throws {
        try validateWorkspaceMutationOperationRecoveryStoreLoaded(
            at: workspaceMutationOperationRecoveryRecords[id]?.sourceURL
        )
        if workspaceMutationTextRecoveryLoadFailed,
           let record = workspaceMutationOperationRecoveryRecords[id],
           !record.textRecoveryRecords.isEmpty
        {
            throw WorkspaceMutationOperationRecoveryError.textRecoveryUnavailable(
                record.sourceURL
            )
        }
        if workspaceMutationOperationRecoveryIDsWithUnpromotedText.contains(id),
           let record = workspaceMutationOperationRecoveryRecords[id]
        {
            try promoteBundledWorkspaceMutationTextRecoveryRecords(record)
            workspaceMutationOperationRecoveryIDsWithUnpromotedText.remove(id)
        }
        do {
            try workspaceMutationOperationRecoveryStore.remove(id: id)
        } catch {
            let removalError = error
            if let record = workspaceMutationOperationRecoveryRecords[id] {
                // `remove` may already have unlinked the journal before directory fsync failed.
                // Restore the exact current record before returning the original remove error.
                try? workspaceMutationOperationRecoveryStore.upsert(record)
            }
            throw removalError
        }
        workspaceMutationOperationRecoveryRecords[id] = nil
    }

    func ensureWorkspaceMutationRecoveryTextIsDurable(
        _ recovery: WorkspaceMutationRecoveryContext
    ) throws {
        for session in recovery.remainingSessions {
            let sessionIdentity = ObjectIdentifier(session)
            guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity]
            else {
                continue
            }
            let logicalRevision = workspaceMutationTextRecoveryLogicalRevision(
                for: session,
                context: context
            )
            if context.persistedRevision != logicalRevision {
                try persistWorkspaceMutationTextRecovery(for: session)
            }
        }
    }

    func markWorkspaceMutationRecoveryBundledTextCommitted(id: UUID) {
        // Keep the journal's text IDs and snapshots until durable removal succeeds. If removal
        // fails and the editor accepts newer input, a failed standalone upsert must still be
        // able to find this journal and synchronously advance its bundled fallback.
        workspaceMutationOperationRecoveryIDsWithUnpromotedText.remove(id)
    }

    @discardableResult
    func persistWorkspaceMutationTextRecoveryInOperationBundle(
        for session: DocumentSession,
        latestRecord: WorkspaceMutationTextRecoveryRecord? = nil
    ) throws -> Bool {
        try validateWorkspaceMutationOperationRecoveryStoreLoaded(
            at: sessionStateURL(for: session) ?? session.fileURL
        )
        let sessionIdentity = ObjectIdentifier(session)
        guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity],
              let latest = latestRecord ?? workspaceMutationTextRecoveryRecord(for: session),
              let operationEntry = workspaceMutationOperationRecoveryRecords
              .sorted(by: { $0.key.uuidString < $1.key.uuidString })
              .first(where: {
                  $0.value.textRecoveryRecords.contains {
                      $0.id == context.recoveryID
                  }
              })
        else {
            return false
        }
        var bundledRecords = operationEntry.value.textRecoveryRecords
        var didUpdateBundle = false
        if let index = bundledRecords.firstIndex(where: { $0.id == context.recoveryID }),
           workspaceMutationTextRecoveryRecord(
               latest,
               isNewerThan: bundledRecords[index]
           )
        {
            bundledRecords[index] = latest
            didUpdateBundle = true
        }
        if didUpdateBundle {
            let updated = operationEntry.value.replacingPayload(
                operationEntry.value.payload,
                textRecoveryRecords: bundledRecords
            )
            try workspaceMutationOperationRecoveryStore.upsert(updated)
            workspaceMutationOperationRecoveryRecords[operationEntry.key] = updated
        }
        workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
            operationEntry.key
        )
        return true
    }

    private func validateWorkspaceMutationOperationRecoveryStoreLoaded(
        at url: URL?
    ) throws {
        guard !workspaceMutationOperationRecoveryLoadFailed else {
            throw AppStateError.workspaceMutationRecoveryUnavailable(
                url
                    ?? workspaceRootURL
                    ?? sessionStateURL(for: currentDocument)
                    ?? currentDocument.fileURL
                    ?? URL(fileURLWithPath: "/")
            )
        }
    }
}

@MainActor
extension AppState {
    func workspaceMutationOperationRecoveryRecord(
        for recovery: WorkspaceMutationRecoveryContext
    ) throws -> WorkspaceMutationOperationRecoveryRecord {
        if case let .unavailable(context) = recovery {
            return context.record
        }
        let payload = workspaceMutationOperationRecoveryPayload(for: recovery)
        var textRecords = recovery.remainingSessions.compactMap {
            workspaceMutationTextRecoveryRecord(for: $0)
        }
        if let existing = workspaceMutationOperationRecoveryRecords[recovery.id] {
            if textRecords.isEmpty, !existing.textRecoveryRecords.isEmpty {
                textRecords = existing.textRecoveryRecords
            }
            textRecords = workspaceMutationTextRecoveryRecords(
                textRecords,
                adjustedFor: recovery
            )
            return existing.replacingPayload(
                payload,
                textRecoveryRecords: textRecords
            )
        }

        textRecords = workspaceMutationTextRecoveryRecords(
            textRecords,
            adjustedFor: recovery
        )
        let rootAuthority = try workspaceMutationRootAuthority(for: recovery)
        let bookmarkData = try SecurityScopedAccess.withAccess(
            to: rootAuthority.securityScopedURL
        ) {
            try rootAuthority.securityScopedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        return WorkspaceMutationOperationRecoveryRecord(
            id: recovery.id,
            updatedAt: Date(),
            rootBookmarkData: bookmarkData,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: payload,
            textRecoveryRecords: textRecords
        )
    }

    func workspaceMutationTextRecoveryRecords(
        _ records: [WorkspaceMutationTextRecoveryRecord],
        adjustedFor recovery: WorkspaceMutationRecoveryContext
    ) -> [WorkspaceMutationTextRecoveryRecord] {
        guard case let .relocation(context) = recovery,
              context.sessionCommitState == .committed
        else {
            return records
        }
        let rekeyedAt = Date()
        return records.map { textRecord in
            guard let relocation = context.records.first(where: {
                exactFileURLSpellingMatches($0.oldURL, textRecord.originalURL)
            }) else {
                return textRecord
            }
            return textRecord.replacingOriginalURL(
                relocation.newURL,
                updatedAt: rekeyedAt
            )
        }
    }

    func workspaceMutationRootAuthority(
        for recovery: WorkspaceMutationRecoveryContext
    ) throws -> WorkspaceFileSystemRootAuthority {
        switch recovery {
        case let .creation(context):
            context.destination.rootAuthority
        case let .relocation(context):
            context.source.rootAuthority
        case let .trash(context):
            context.source.rootAuthority
        case let .unavailable(context):
            throw WorkspaceMutationOperationRecoveryError.rootBookmarkUnavailable(
                context.record.sourceURL
            )
        }
    }

    func workspaceMutationOperationRecoveryPayload(
        for recovery: WorkspaceMutationRecoveryContext
    ) -> WorkspaceMutationOperationRecoveryRecord.Payload {
        switch recovery {
        case let .creation(context):
            let publicationPhase:
                WorkspaceMutationOperationRecoveryRecord.CreationPublicationPhase? =
                    switch context.publicationState {
                    case .unknown:
                        nil
                    case .planned:
                        .planned
                    case .prepared:
                        .prepared
                    case .committed:
                        .committedCleanup
                    }
            let recoveryState: WorkspaceMutationOperationRecoveryRecord.CreationRecoveryState =
                switch context.recoveryState {
                case .none:
                    .none
                case let .removalIndeterminate(location):
                    .removalIndeterminate(relativePath: location.relativePath)
                case let .retained(location):
                    .retained(relativePath: location.relativePath)
                case .unknown:
                    .unknown
                }
            return .creation(.init(
                destinationRelativePath: context.destination.relativePath,
                kind: context.kind == .file ? .file : .folder,
                parentExpectation: context.parentExpectation.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                ),
                destinationParentBookmarkData:
                context.destinationParentBookmarkData,
                destinationParentDisplayURL: context.destinationParentDisplayURL,
                destinationLeafName: context.destinationLeafName,
                destinationParentAuthorityExpectation:
                context.destinationParentAuthorityExpectation.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                ),
                publicationPhase: publicationPhase,
                isPlanned: context.isPlanned,
                expectedCreatedItem: context.expectedCreatedItem.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                ),
                createdItemBookmarkData: context.createdItemBookmarkData,
                createdItemDisplayURL: context.createdItemDisplayURL,
                reason: .init(context.reason),
                recoveryState: recoveryState,
                recoveryExpectation: context.recoveryExpectation.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                ),
                publicationSourceRelativePath: context.publicationSource?.relativePath,
                actualPublishedExpectation: context.actualPublishedExpectation.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                )
            ))
        case let .relocation(context):
            let sessionCommitPhase:
                WorkspaceMutationOperationRecoveryRecord.RelocationSessionCommitPhase? =
                    switch context.sessionCommitState {
                    case .unknown:
                        nil
                    case .pending:
                        .pendingSessionCommit
                    case .committed:
                        .committedCleanup
                    }
            return .relocation(.init(
                sourceRelativePath: context.source.relativePath,
                destinationRelativePath: context.destination.relativePath,
                expectation: .init(context.expectation),
                sourceParentExpectation: .init(context.sourceParentExpectation),
                destinationParentExpectation: .init(context.destinationParentExpectation),
                sourceParentBookmarkData: context.sourceParentBookmarkData,
                sourceParentDisplayURL: context.sourceParentDisplayURL,
                sourceLeafName: context.sourceLeafName,
                sourceParentAuthorityExpectation:
                .init(context.sourceParentAuthorityExpectation),
                destinationParentBookmarkData: context.destinationParentBookmarkData,
                destinationParentDisplayURL: context.destinationParentDisplayURL,
                destinationLeafName: context.destinationLeafName,
                destinationParentAuthorityExpectation:
                .init(context.destinationParentAuthorityExpectation),
                relocatedItemBookmarkData: context.relocatedItemBookmarkData,
                relocatedItemDisplayURL: context.relocatedItemDisplayURL,
                sessionCommitPhase: sessionCommitPhase,
                reason: .init(context.reason),
                actualMovedExpectation: context.actualMovedExpectation.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                )
            ))
        case let .trash(context):
            return .trash(workspaceTrashMutationOperationRecoveryPayload(for: context))
        case let .unavailable(context):
            return context.record.payload
        }
    }

    func workspaceTrashMutationOperationRecoveryPayload(
        for context: WorkspaceTrashRecoveryContext
    ) -> WorkspaceMutationOperationRecoveryRecord.Trash {
        let cleanupState: WorkspaceMutationOperationRecoveryRecord.TrashCleanupState =
            switch context.cleanupState {
            case .notCreated:
                .notCreated
            case let .removalIndeterminate(location):
                .removalIndeterminate(relativePath: location.relativePath)
            case .removed:
                .removed
            }
        let sessionCommitPhase:
            WorkspaceMutationOperationRecoveryRecord.TrashSessionCommitPhase? =
                switch context.sessionCommitState {
                case .unknown:
                    nil
                case .pending:
                    .pendingSessionCommit
                case .committed:
                    .committedCleanup
                }
        return .init(
            sourceRelativePath: context.source.relativePath,
            expectation: .init(context.expectation),
            sourceParentExpectation: .init(context.sourceParentExpectation),
            sourceParentBookmarkData: context.sourceParentBookmarkData,
            sourceParentDisplayURL: context.sourceParentDisplayURL,
            sourceLeafName: context.sourceLeafName,
            sourceParentAuthorityExpectation:
            .init(context.sourceParentAuthorityExpectation),
            expectedItemBookmarkData: context.expectedItemBookmarkData,
            expectedItemDisplayURL: context.expectedItemDisplayURL,
            sessionCommitPhase: sessionCommitPhase,
            reason: .init(context.reason),
            recoveryRelativePath: context.recoveryLocation?.relativePath,
            reportedTrashURL: context.reportedTrashURL,
            reportedTrashBookmarkData: context.reportedTrashBookmarkData,
            cleanupState: cleanupState,
            actualStagedExpectation: context.actualStagedExpectation.map(
                WorkspaceMutationOperationRecoveryRecord.Expectation.init
            ),
            actualStagedEntryRecoveryRelativePath:
            context.actualStagedEntryRecoveryLocation?.relativePath
        )
    }

    struct RestoredRecoveryAuthorities {
        let creationDestinationParentLocation: WorkspaceFileSystemLocation?
        let creationCreatedItemLocation: WorkspaceFileSystemLocation?
        let sourceParentLocation: WorkspaceFileSystemLocation?
        let destinationParentLocation: WorkspaceFileSystemLocation?
        let relocatedItemLocation: WorkspaceFileSystemLocation?
        let trashExpectedItemLocation: WorkspaceFileSystemLocation?
        let trashSourceParentLocation: WorkspaceFileSystemLocation?
        let reportedTrashLocation: WorkspaceFileSystemLocation?
        let reportedTrashDisplayURL: URL?

        init(
            creationDestinationParentLocation: WorkspaceFileSystemLocation? = nil,
            creationCreatedItemLocation: WorkspaceFileSystemLocation? = nil,
            sourceParentLocation: WorkspaceFileSystemLocation?,
            destinationParentLocation: WorkspaceFileSystemLocation?,
            relocatedItemLocation: WorkspaceFileSystemLocation?,
            trashExpectedItemLocation: WorkspaceFileSystemLocation?,
            trashSourceParentLocation: WorkspaceFileSystemLocation?,
            reportedTrashLocation: WorkspaceFileSystemLocation?,
            reportedTrashDisplayURL: URL?
        ) {
            self.creationDestinationParentLocation =
                creationDestinationParentLocation
            self.creationCreatedItemLocation = creationCreatedItemLocation
            self.sourceParentLocation = sourceParentLocation
            self.destinationParentLocation = destinationParentLocation
            self.relocatedItemLocation = relocatedItemLocation
            self.trashExpectedItemLocation = trashExpectedItemLocation
            self.trashSourceParentLocation = trashSourceParentLocation
            self.reportedTrashLocation = reportedTrashLocation
            self.reportedTrashDisplayURL = reportedTrashDisplayURL
        }
    }

    // swiftlint:disable:next function_body_length
    func workspaceMutationRecoveryContext(
        from record: WorkspaceMutationOperationRecoveryRecord,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        restoredAuthorities: RestoredRecoveryAuthorities
    ) throws -> WorkspaceMutationRecoveryContext {
        switch record.payload {
        case let .creation(context):
            let publicationState: WorkspaceCreationPublicationState =
                switch context.publicationPhase {
                case nil:
                    .unknown
                case .planned?:
                    .planned
                case .prepared?:
                    .prepared
                case .committedCleanup?:
                    .committed
                }
            let recoveryState: WorkspaceItemCreationRecoveryState =
                switch context.recoveryState {
                case .none:
                    .none
                case let .removalIndeterminate(relativePath):
                    try .removalIndeterminate(
                        rootAuthority.location(relativePath: relativePath)
                    )
                case let .retained(relativePath):
                    try .retained(rootAuthority.location(relativePath: relativePath))
                case .unknown:
                    .unknown
                }
            return try .creation(.init(
                id: record.id,
                destination: rootAuthority.location(
                    relativePath: context.destinationRelativePath
                ),
                kind: context.kind == .file ? .file : .folder,
                parentExpectation: context.parentExpectation?.runtimeValue,
                destinationParentBookmarkData:
                context.destinationParentBookmarkData,
                destinationParentDisplayURL: context.destinationParentDisplayURL,
                destinationLeafName: context.destinationLeafName,
                destinationParentAuthorityExpectation:
                context.destinationLocatorParentExpectation?.runtimeValue,
                destinationParentAuthorityLocation:
                restoredAuthorities.creationDestinationParentLocation,
                publicationState: publicationState,
                isPlanned: context.isPlanned ?? false,
                expectedCreatedItem: context.expectedCreatedItem?.runtimeValue,
                reason: context.reason.runtimeValue,
                recoveryState: recoveryState,
                recoveryExpectation: context.recoveryExpectation?.runtimeValue,
                publicationSource: context.publicationSourceRelativePath.map {
                    try rootAuthority.location(relativePath: $0)
                },
                createdItemBookmarkData: context.createdItemBookmarkData,
                createdItemDisplayURL: context.createdItemDisplayURL,
                createdItemAuthorityLocation:
                restoredAuthorities.creationCreatedItemLocation,
                actualPublishedExpectation:
                context.actualPublishedExpectation?.runtimeValue
            ))
        case let .relocation(context):
            return try .relocation(workspaceRelocationRecoveryContext(
                from: context,
                recordID: record.id,
                rootAuthority: rootAuthority,
                restoredAuthorities: restoredAuthorities
            ))
        case let .trash(context):
            let sessionCommitState: WorkspaceTrashSessionCommitState =
                switch context.sessionCommitPhase {
                case nil:
                    .unknown
                case .pendingSessionCommit?:
                    .pending
                case .committedCleanup?:
                    .committed
                }
            let cleanupState: WorkspaceTrashStagingCleanupState =
                switch context.cleanupState {
                case .notCreated:
                    .notCreated
                case let .removalIndeterminate(relativePath):
                    try .removalIndeterminate(
                        rootAuthority.location(relativePath: relativePath)
                    )
                case .removed:
                    .removed
                }
            return try .trash(.init(
                id: record.id,
                source: rootAuthority.location(relativePath: context.sourceRelativePath),
                expectation: context.expectation.runtimeValue,
                sourceParentExpectation: context.sourceParentExpectation.runtimeValue,
                sourceParentBookmarkData: context.sourceParentBookmarkData,
                sourceParentDisplayURL: context.sourceParentDisplayURL,
                sourceLeafName: context.sourceLeafName,
                sourceParentAuthorityExpectation:
                context.sourceLocatorParentExpectation.runtimeValue,
                sourceParentAuthorityLocation:
                restoredAuthorities.trashSourceParentLocation,
                expectedItemBookmarkData: context.expectedItemBookmarkData,
                expectedItemDisplayURL: context.expectedItemDisplayURL,
                expectedItemAuthorityLocation:
                restoredAuthorities.trashExpectedItemLocation,
                sessionCommitState: sessionCommitState,
                reason: context.reason.runtimeValue,
                recoveryLocation: context.recoveryRelativePath.map {
                    try rootAuthority.location(relativePath: $0)
                },
                reportedTrashURL:
                restoredAuthorities.reportedTrashDisplayURL ?? context.reportedTrashURL,
                reportedTrashBookmarkData: context.reportedTrashBookmarkData,
                reportedTrashAuthorityLocation: restoredAuthorities.reportedTrashLocation,
                cleanupState: cleanupState,
                actualStagedExpectation: context.actualStagedExpectation?.runtimeValue,
                actualStagedEntryRecoveryLocation:
                context.actualStagedEntryRecoveryRelativePath.map {
                    try rootAuthority.location(relativePath: $0)
                },
                records: [],
                remainingSessionIDs: []
            ))
        }
    }

    func workspaceRelocationRecoveryContext(
        from context: WorkspaceMutationOperationRecoveryRecord.Relocation,
        recordID: UUID,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        restoredAuthorities: RestoredRecoveryAuthorities
    ) throws -> WorkspaceRelocationRecoveryContext {
        let sessionCommitState: WorkspaceRelocationSessionCommitState =
            switch context.sessionCommitPhase {
            case nil:
                .unknown
            case .pendingSessionCommit?:
                .pending
            case .committedCleanup?:
                .committed
            }
        return try WorkspaceRelocationRecoveryContext(
            id: recordID,
            source: rootAuthority.location(relativePath: context.sourceRelativePath),
            destination: rootAuthority.location(relativePath: context.destinationRelativePath),
            expectation: context.expectation.runtimeValue,
            sourceParentExpectation: context.sourceParentExpectation.runtimeValue,
            destinationParentExpectation: context.destinationParentExpectation.runtimeValue,
            sourceParentBookmarkData: context.sourceParentBookmarkData,
            sourceParentDisplayURL: context.sourceParentDisplayURL,
            sourceLeafName: context.sourceLeafName,
            sourceParentAuthorityExpectation:
            context.sourceLocatorParentExpectation.runtimeValue,
            sourceParentAuthorityLocation: restoredAuthorities.sourceParentLocation,
            destinationParentBookmarkData: context.destinationParentBookmarkData,
            destinationParentDisplayURL: context.destinationParentDisplayURL,
            destinationLeafName: context.destinationLeafName,
            destinationParentAuthorityExpectation:
            context.destinationLocatorParentExpectation.runtimeValue,
            destinationParentAuthorityLocation: restoredAuthorities.destinationParentLocation,
            relocatedItemBookmarkData: context.relocatedItemBookmarkData,
            relocatedItemDisplayURL: context.relocatedItemDisplayURL,
            relocatedItemAuthorityLocation: restoredAuthorities.relocatedItemLocation,
            sessionCommitState: sessionCommitState,
            reason: context.reason.runtimeValue,
            actualMovedExpectation: context.actualMovedExpectation?.runtimeValue,
            records: [],
            remainingSessionIDs: []
        )
    }

    func workspaceTrashRecoveryContextCapturingReportedAuthorityIfPossible(
        _ installedContext: WorkspaceTrashRecoveryContext
    ) -> WorkspaceTrashRecoveryContext {
        var context = installedContext
        guard let reportedTrashURL = context.reportedTrashURL else {
            context.reportedTrashBookmarkData = nil
            context.reportedTrashAuthorityLocation = nil
            return context
        }

        guard let authority = try? captureWorkspaceMutationItemBookmarkAuthority(
            at: reportedTrashURL,
            expecting: context.expectation
        ) else {
            context.reportedTrashBookmarkData = nil
            context.reportedTrashAuthorityLocation = nil
            return context
        }
        context.reportedTrashURL = authority.displayURL
        context.reportedTrashBookmarkData = authority.bookmarkData
        context.reportedTrashAuthorityLocation = authority.location
        return context
    }

    /// Captures the exact original source slot plus a supplementary expected-item bookmark and
    /// persists both in one pending-phase journal before Trash can move the item to staging.
    /// The parent-entry authority, not the item bookmark alone, authorizes any later automatic
    /// restoration to the source spelling.
    func prepareWorkspaceTrashRecoveryIntent(
        _ installedContext: WorkspaceTrashRecoveryContext
    ) throws -> WorkspaceTrashRecoveryContext {
        let sourceParentAuthority = try SecurityScopedAccess.withAccess(
            to: installedContext.source.securityScopedURL
        ) {
            let standaloneSource = try WorkspaceFileSystemLocation(
                fileURL: installedContext.source.fileURL
            )
            return try captureWorkspaceMutationBookmarkAuthority(
                at: standaloneSource.rootAuthority.canonicalRootURL,
                destinationLeafName: standaloneSource.relativePath,
                expectingParent: installedContext.sourceParentExpectation
            )
        }
        let expectedItemAuthority = try captureWorkspaceMutationItemBookmarkAuthority(
            at: installedContext.source.fileURL,
            expecting: installedContext.expectation
        )
        var context = installedContext
        context.sourceParentBookmarkData = sourceParentAuthority.bookmarkData
        context.sourceParentDisplayURL = sourceParentAuthority.displayURL
        context.sourceLeafName = sourceParentAuthority.location.relativePath
        context.sourceParentAuthorityExpectation =
            installedContext.sourceParentExpectation
        context.sourceParentAuthorityLocation = sourceParentAuthority.location
        context.expectedItemBookmarkData = expectedItemAuthority.bookmarkData
        context.expectedItemDisplayURL = expectedItemAuthority.displayURL
        context.expectedItemAuthorityLocation = expectedItemAuthority.location
        context.sessionCommitState = .pending
        try persistWorkspaceMutationRecoveryIntent(.trash(context))
        return context
    }

    /// Write-ahead authority for an expected-item recovery rename. The bookmark is resolved and
    /// exact-identity checked before it is persisted, so a crash after the rename cannot leave
    /// the journal with only a stale root-relative staging path.
    func prepareWorkspaceTrashExpectedItemRecoveryAuthority(
        _ installedContext: WorkspaceTrashRecoveryContext,
        at itemLocation: WorkspaceFileSystemLocation
    ) throws -> WorkspaceTrashRecoveryContext {
        let authority = try captureWorkspaceMutationItemBookmarkAuthority(
            at: itemLocation.fileURL,
            expecting: installedContext.expectation
        )
        var context = installedContext
        context.expectedItemBookmarkData = authority.bookmarkData
        context.expectedItemDisplayURL = authority.displayURL
        context.expectedItemAuthorityLocation = authority.location
        try persistWorkspaceMutationRecoveryUpdate(.trash(context))
        return context
    }

    /// Persists the post-recycler phase before App/session state is committed. A reported URL
    /// is never accepted as authority on its own: the journal advances only after the returned
    /// bookmark resolves back to the exact trashed item identity.
    func prepareWorkspaceTrashCommittedRecovery(
        _ installedContext: WorkspaceTrashRecoveryContext,
        reportedTrashURL: URL
    ) throws -> WorkspaceTrashRecoveryContext {
        let authority = try captureWorkspaceMutationItemBookmarkAuthority(
            at: reportedTrashURL,
            expecting: installedContext.expectation
        )
        var context = installedContext
        context.reportedTrashURL = authority.displayURL
        context.reportedTrashBookmarkData = authority.bookmarkData
        context.reportedTrashAuthorityLocation = authority.location
        context.sessionCommitState = .committed
        try persistWorkspaceMutationRecoveryUpdate(.trash(context))
        return context
    }

    /// Re-resolves every durable Trash authority for each reconciliation attempt. Persisted
    /// bookmark bytes remain visible when resolution fails, while the corresponding runtime
    /// location is cleared so callers can distinguish an unavailable authority from a legacy
    /// journal that never captured one.
    func resolveWorkspaceTrashAuthorities(
        _ installedContext: WorkspaceTrashRecoveryContext
    ) throws -> WorkspaceTrashRecoveryContext {
        guard var record = workspaceMutationOperationRecoveryRecords[installedContext.id],
              case .trash = record.payload
        else {
            var unavailable = installedContext
            unavailable.sourceParentAuthorityLocation = nil
            unavailable.expectedItemAuthorityLocation = nil
            unavailable.reportedTrashAuthorityLocation = nil
            unavailable.sessionCommitState = .unknown
            workspaceMutationRecoveries[unavailable.id] = .trash(unavailable)
            return unavailable
        }

        let sourceParentRestoration = recordRestoringTrashSourceParent(record)
        record = sourceParentRestoration.record
        let expectedItemRestoration = recordRestoringTrashExpectedItemAuthority(record)
        record = expectedItemRestoration.record
        let reportedTrashRestoration = recordRestoringReportedTrashAuthority(record)
        record = reportedTrashRestoration.record
        let didRefreshDurableAuthority = sourceParentRestoration.didUpdate ||
            expectedItemRestoration.didUpdate ||
            reportedTrashRestoration.didUpdate
        if didRefreshDurableAuthority {
            try workspaceMutationOperationRecoveryStore.upsert(record)
            workspaceMutationOperationRecoveryRecords[record.id] = record
        }

        guard case let .trash(durable) = record.payload else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(
                installedContext.source.fileURL
            )
        }
        var updated = installedContext
        updated.sourceParentBookmarkData = durable.sourceParentBookmarkData
        updated.sourceParentDisplayURL = durable.sourceParentDisplayURL
        updated.sourceLeafName = durable.sourceLeafName
        updated.sourceParentAuthorityExpectation =
            durable.sourceLocatorParentExpectation.runtimeValue
        updated.sourceParentAuthorityLocation = sourceParentRestoration.authority.location
        updated.expectedItemBookmarkData = durable.expectedItemBookmarkData
        updated.expectedItemDisplayURL = durable.expectedItemDisplayURL
        updated.expectedItemAuthorityLocation = expectedItemRestoration.authority.location
        updated.reportedTrashURL = durable.reportedTrashURL
        updated.reportedTrashBookmarkData = durable.reportedTrashBookmarkData
        updated.reportedTrashAuthorityLocation = reportedTrashRestoration.authority.location
        updated.sessionCommitState = switch durable.sessionCommitPhase {
        case nil:
            .unknown
        case .pendingSessionCommit?:
            .pending
        case .committedCleanup?:
            .committed
        }
        workspaceMutationRecoveries[updated.id] = .trash(updated)
        return updated
    }

    /// Re-resolves the two durable creation locators from the journal. Runtime locations are
    /// deliberately cleared when resolution fails; a recorded display URL never substitutes for
    /// bookmark authority at the terminal publication seam.
    func resolveWorkspaceCreationAuthorities(
        _ installedContext: WorkspaceCreationRecoveryContext
    ) throws -> WorkspaceCreationRecoveryContext {
        guard var record = workspaceMutationOperationRecoveryRecords[installedContext.id],
              case .creation = record.payload
        else {
            var unavailable = installedContext
            unavailable.destinationParentAuthorityLocation = nil
            unavailable.createdItemAuthorityLocation = nil
            workspaceMutationRecoveries[unavailable.id] = .creation(unavailable)
            return unavailable
        }

        let parentRestoration = recordRestoringCreationDestinationParent(record)
        record = parentRestoration.record
        let itemRestoration = recordRestoringCreationCreatedItem(record)
        record = itemRestoration.record
        if parentRestoration.didUpdate || itemRestoration.didUpdate {
            try workspaceMutationOperationRecoveryStore.upsert(record)
            workspaceMutationOperationRecoveryRecords[record.id] = record
        }

        guard case let .creation(durable) = record.payload else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(
                installedContext.destination.fileURL
            )
        }
        var updated = installedContext
        updated.destinationParentBookmarkData =
            durable.destinationParentBookmarkData
        updated.destinationParentDisplayURL = durable.destinationParentDisplayURL
        updated.destinationLeafName = durable.destinationLeafName
        updated.destinationParentAuthorityExpectation =
            durable.destinationLocatorParentExpectation?.runtimeValue
        updated.destinationParentAuthorityLocation =
            parentRestoration.authority.location
        updated.publicationState = switch durable.publicationPhase {
        case nil:
            .unknown
        case .planned?:
            .planned
        case .prepared?:
            .prepared
        case .committedCleanup?:
            .committed
        }
        updated.createdItemBookmarkData = durable.createdItemBookmarkData
        updated.createdItemDisplayURL = durable.createdItemDisplayURL
        updated.createdItemAuthorityLocation = itemRestoration.authority.location
        workspaceMutationRecoveries[updated.id] = .creation(updated)
        return updated
    }

    func workspaceMutationTextRecoveryRecord(
        for session: DocumentSession
    ) -> WorkspaceMutationTextRecoveryRecord? {
        let sessionIdentity = ObjectIdentifier(session)
        guard let context = workspaceMutationTextRecoveryContexts[sessionIdentity] else {
            return nil
        }
        return WorkspaceMutationTextRecoveryRecord(
            id: context.recoveryID,
            originalURL: context.originalURL,
            fileKind: context.fileKind,
            source: session.text,
            revision: workspaceMutationTextRecoveryLogicalRevision(
                for: session,
                context: context
            ),
            reason: context.reason
        )
    }

    struct WorkspaceMutationBookmarkAuthority {
        let location: WorkspaceFileSystemLocation
        let bookmarkData: Data
        let displayURL: URL
    }

    struct RestoredMutationBookmarkAuthority {
        let location: WorkspaceFileSystemLocation?
        let refreshedBookmarkData: Data?
        let displayURL: URL?
    }

    /// Captures a restart-durable bookmark and proves that resolving that exact bookmark still
    /// identifies the expected destination parent. The returned child location is rooted in
    /// that resolved parent, so its retained descriptor continues naming the parent even if the
    /// parent is subsequently moved. The caller's URL is never retained as authority.
    func captureWorkspaceMutationBookmarkAuthority(
        at destinationParentURL: URL,
        destinationLeafName: String,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceMutationBookmarkAuthority {
        let bookmarkData = try workspaceMutationBookmarkAccess.makeBookmark(
            for: destinationParentURL
        )
        let resolution = try workspaceMutationBookmarkAccess.resolveBookmark(bookmarkData)
        guard let location = standaloneWorkspaceMutationChildLocation(
            parentURL: resolution.fileURL,
            leafName: destinationLeafName,
            expectingParent: parentExpectation
        ) else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(destinationParentURL)
        }

        guard resolution.isStale else {
            return WorkspaceMutationBookmarkAuthority(
                location: location,
                bookmarkData: bookmarkData,
                displayURL: resolution.fileURL
            )
        }

        let refreshedBookmarkData = try workspaceMutationBookmarkAccess.makeBookmark(
            for: resolution.fileURL
        )
        let refreshedResolution = try workspaceMutationBookmarkAccess.resolveBookmark(
            refreshedBookmarkData
        )
        guard !refreshedResolution.isStale,
              let refreshedLocation = standaloneWorkspaceMutationChildLocation(
                  parentURL: refreshedResolution.fileURL,
                  leafName: destinationLeafName,
                  expectingParent: parentExpectation
              )
        else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(destinationParentURL)
        }
        return WorkspaceMutationBookmarkAuthority(
            location: refreshedLocation,
            bookmarkData: refreshedBookmarkData,
            displayURL: refreshedResolution.fileURL
        )
    }

    /// Captures durable authority for the source item itself and proves that bookmark resolution
    /// still identifies the exact inode and kind expected by the relocation plan.
    func captureWorkspaceMutationItemBookmarkAuthority(
        at itemURL: URL,
        expecting expectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceMutationBookmarkAuthority {
        let bookmarkData = try workspaceMutationBookmarkAccess.makeBookmark(for: itemURL)
        let resolution = try workspaceMutationBookmarkAccess.resolveBookmark(bookmarkData)
        guard let location = standaloneWorkspaceMutationLocation(
            at: resolution.fileURL,
            expecting: expectation
        ) else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(itemURL)
        }

        guard resolution.isStale else {
            return WorkspaceMutationBookmarkAuthority(
                location: location,
                bookmarkData: bookmarkData,
                displayURL: resolution.fileURL
            )
        }

        let refreshedBookmarkData = try workspaceMutationBookmarkAccess.makeBookmark(
            for: resolution.fileURL
        )
        let refreshedResolution = try workspaceMutationBookmarkAccess.resolveBookmark(
            refreshedBookmarkData
        )
        guard !refreshedResolution.isStale,
              let refreshedLocation = standaloneWorkspaceMutationLocation(
                  at: refreshedResolution.fileURL,
                  expecting: expectation
              )
        else {
            throw WorkspaceMutationOperationRecoveryError.invalidRecord(itemURL)
        }
        return WorkspaceMutationBookmarkAuthority(
            location: refreshedLocation,
            bookmarkData: refreshedBookmarkData,
            displayURL: refreshedResolution.fileURL
        )
    }

    func restoredCreationDestinationParentAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .creation(context) = record.payload,
              let parentExpectation = context.destinationLocatorParentExpectation
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationParentEntryAuthority(
            bookmarkData: context.destinationParentBookmarkData,
            recordedDisplayURL: context.destinationParentDisplayURL,
            leafName: context.destinationLeafName,
            expectingParent: parentExpectation.runtimeValue
        )
    }

    func restoredCreationCreatedItemAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .creation(context) = record.payload,
              let expectation = context.expectedCreatedItem ??
              context.recoveryExpectation
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationBookmarkAuthority(
            bookmarkData: context.createdItemBookmarkData,
            recordedDisplayURL: context.createdItemDisplayURL,
            expecting: expectation.runtimeValue
        )
    }

    func restoredTrashSourceParentAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .trash(context) = record.payload else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationParentEntryAuthority(
            bookmarkData: context.sourceParentBookmarkData,
            recordedDisplayURL: context.sourceParentDisplayURL,
            leafName: context.sourceLeafName,
            expectingParent: context.sourceLocatorParentExpectation.runtimeValue
        )
    }

    func restoredWorkspaceMutationParentEntryAuthority(
        bookmarkData: Data?,
        recordedDisplayURL: URL?,
        leafName: String?,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation
    ) -> RestoredMutationBookmarkAuthority {
        guard let bookmarkData,
              let leafName,
              let resolution = try? workspaceMutationBookmarkAccess
              .resolveBookmark(bookmarkData),
              let location = standaloneWorkspaceMutationChildLocation(
                  parentURL: resolution.fileURL,
                  leafName: leafName,
                  expectingParent: parentExpectation
              )
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }

        if resolution.isStale {
            guard let refreshedBookmarkData = try? workspaceMutationBookmarkAccess
                .makeBookmark(for: resolution.fileURL),
                let refreshedResolution = try? workspaceMutationBookmarkAccess
                .resolveBookmark(refreshedBookmarkData),
                !refreshedResolution.isStale,
                let refreshedLocation = standaloneWorkspaceMutationChildLocation(
                    parentURL: refreshedResolution.fileURL,
                    leafName: leafName,
                    expectingParent: parentExpectation
                )
            else {
                return RestoredMutationBookmarkAuthority(
                    location: nil,
                    refreshedBookmarkData: nil,
                    displayURL: nil
                )
            }
            return RestoredMutationBookmarkAuthority(
                location: refreshedLocation,
                refreshedBookmarkData: refreshedBookmarkData,
                displayURL: refreshedResolution.fileURL
            )
        }

        let displayURLChanged = recordedDisplayURL != resolution.fileURL
        return RestoredMutationBookmarkAuthority(
            location: location,
            refreshedBookmarkData: displayURLChanged ? bookmarkData : nil,
            displayURL: resolution.fileURL
        )
    }

    func restoredRelocationSourceParentAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .relocation(context) = record.payload,
              let bookmarkData = context.sourceParentBookmarkData,
              let sourceLeafName = context.sourceLeafName,
              let resolution = try? workspaceMutationBookmarkAccess
              .resolveBookmark(bookmarkData),
              let location = standaloneWorkspaceMutationChildLocation(
                  parentURL: resolution.fileURL,
                  leafName: sourceLeafName,
                  expectingParent:
                  context.sourceLocatorParentExpectation.runtimeValue
              )
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }

        if resolution.isStale {
            guard let refreshedBookmarkData = try? workspaceMutationBookmarkAccess.makeBookmark(
                for: resolution.fileURL
            ),
                let refreshedResolution = try? workspaceMutationBookmarkAccess.resolveBookmark(
                    refreshedBookmarkData
                ),
                !refreshedResolution.isStale,
                let refreshedLocation = standaloneWorkspaceMutationChildLocation(
                    parentURL: refreshedResolution.fileURL,
                    leafName: sourceLeafName,
                    expectingParent:
                    context.sourceLocatorParentExpectation.runtimeValue
                )
            else {
                return RestoredMutationBookmarkAuthority(
                    location: nil,
                    refreshedBookmarkData: nil,
                    displayURL: nil
                )
            }
            return RestoredMutationBookmarkAuthority(
                location: refreshedLocation,
                refreshedBookmarkData: refreshedBookmarkData,
                displayURL: refreshedResolution.fileURL
            )
        }

        let displayURLChanged = context.sourceParentDisplayURL != resolution.fileURL
        return RestoredMutationBookmarkAuthority(
            location: location,
            refreshedBookmarkData: displayURLChanged ? bookmarkData : nil,
            displayURL: resolution.fileURL
        )
    }

    func restoredRelocationDestinationParentAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .relocation(context) = record.payload else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        guard let bookmarkData = context.destinationParentBookmarkData,
              let destinationLeafName = context.destinationLeafName,
              let resolution = try? workspaceMutationBookmarkAccess
              .resolveBookmark(bookmarkData),
              let location = standaloneWorkspaceMutationChildLocation(
                  parentURL: resolution.fileURL,
                  leafName: destinationLeafName,
                  expectingParent:
                  context.destinationLocatorParentExpectation.runtimeValue
              )
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }

        if resolution.isStale {
            guard let refreshedBookmarkData = try? workspaceMutationBookmarkAccess.makeBookmark(
                for: resolution.fileURL
            ),
                let refreshedResolution = try? workspaceMutationBookmarkAccess.resolveBookmark(
                    refreshedBookmarkData
                ),
                !refreshedResolution.isStale,
                let refreshedLocation = standaloneWorkspaceMutationChildLocation(
                    parentURL: refreshedResolution.fileURL,
                    leafName: destinationLeafName,
                    expectingParent:
                    context.destinationLocatorParentExpectation.runtimeValue
                )
            else {
                return RestoredMutationBookmarkAuthority(
                    location: nil,
                    refreshedBookmarkData: nil,
                    displayURL: nil
                )
            }
            return RestoredMutationBookmarkAuthority(
                location: refreshedLocation,
                refreshedBookmarkData: refreshedBookmarkData,
                displayURL: refreshedResolution.fileURL
            )
        }

        let displayURLChanged = context.destinationParentDisplayURL != resolution.fileURL
        return RestoredMutationBookmarkAuthority(
            location: location,
            refreshedBookmarkData: displayURLChanged ? bookmarkData : nil,
            displayURL: resolution.fileURL
        )
    }

    func restoredRelocationItemAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .relocation(context) = record.payload else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationBookmarkAuthority(
            bookmarkData: context.relocatedItemBookmarkData,
            recordedDisplayURL: context.relocatedItemDisplayURL,
            expecting: context.expectation.runtimeValue
        )
    }

    func restoredTrashExpectedItemAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .trash(context) = record.payload else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationBookmarkAuthority(
            bookmarkData: context.expectedItemBookmarkData,
            recordedDisplayURL: context.expectedItemDisplayURL,
            expecting: context.expectation.runtimeValue
        )
    }

    func restoredReportedTrashAuthority(
        from record: WorkspaceMutationOperationRecoveryRecord
    ) -> RestoredMutationBookmarkAuthority {
        guard case let .trash(context) = record.payload else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }
        return restoredWorkspaceMutationBookmarkAuthority(
            bookmarkData: context.reportedTrashBookmarkData,
            recordedDisplayURL: context.reportedTrashURL,
            expecting: context.expectation.runtimeValue
        )
    }

    func restoredWorkspaceMutationBookmarkAuthority(
        bookmarkData: Data?,
        recordedDisplayURL: URL?,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> RestoredMutationBookmarkAuthority {
        guard let bookmarkData,
              let resolution = try? workspaceMutationBookmarkAccess
              .resolveBookmark(bookmarkData),
              let location = standaloneWorkspaceMutationLocation(
                  at: resolution.fileURL,
                  expecting: expectation
              )
        else {
            return RestoredMutationBookmarkAuthority(
                location: nil,
                refreshedBookmarkData: nil,
                displayURL: nil
            )
        }

        if resolution.isStale {
            guard let refreshedBookmarkData =
                try? workspaceMutationBookmarkAccess.makeBookmark(
                    for: resolution.fileURL
                ),
                let refreshedResolution = try? workspaceMutationBookmarkAccess.resolveBookmark(
                    refreshedBookmarkData
                ),
                !refreshedResolution.isStale,
                let refreshedLocation = standaloneWorkspaceMutationLocation(
                    at: refreshedResolution.fileURL,
                    expecting: expectation
                )
            else {
                return RestoredMutationBookmarkAuthority(
                    location: nil,
                    refreshedBookmarkData: nil,
                    displayURL: nil
                )
            }
            return RestoredMutationBookmarkAuthority(
                location: refreshedLocation,
                refreshedBookmarkData: refreshedBookmarkData,
                displayURL: refreshedResolution.fileURL
            )
        }

        let displayURLChanged = recordedDisplayURL != resolution.fileURL
        return RestoredMutationBookmarkAuthority(
            location: location,
            refreshedBookmarkData: displayURLChanged ? bookmarkData : nil,
            displayURL: resolution.fileURL
        )
    }

    func standaloneWorkspaceMutationLocation(
        at fileURL: URL,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSystemLocation? {
        try? SecurityScopedAccess.withAccess(to: fileURL) {
            let location = try WorkspaceFileSystemLocation(fileURL: fileURL)
            guard workspaceMutationExactExpectationState(
                at: location,
                expecting: expectation,
                parentExpectation: nil
            ) == .expected else {
                throw WorkspaceMutationOperationRecoveryError.invalidRecord(fileURL)
            }
            return location
        }
    }

    func standaloneWorkspaceMutationChildLocation(
        parentURL: URL,
        leafName: String,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSystemLocation? {
        guard !leafName.isEmpty,
              leafName != ".",
              leafName != "..",
              !leafName.contains("/"),
              !leafName.utf8.contains(0)
        else {
            return nil
        }
        return try? SecurityScopedAccess.withAccess(to: parentURL) {
            let parentAuthority = try WorkspaceFileSystemRootAuthority(
                rootURL: parentURL,
                securityScopedURL: parentURL
            )
            guard parentAuthority.directoryMutationExpectation == parentExpectation else {
                throw WorkspaceMutationOperationRecoveryError.invalidRecord(parentURL)
            }
            return try parentAuthority.location(relativePath: leafName)
        }
    }

    func standaloneReportedTrashLocation(
        at fileURL: URL,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSystemLocation? {
        standaloneWorkspaceMutationLocation(at: fileURL, expecting: expectation)
    }

    func mergeAndPromoteBundledWorkspaceMutationTextRecoveryRecords(
        from operationRecords: [WorkspaceMutationOperationRecoveryRecord]
    ) {
        if workspaceMutationTextRecoveryLoadFailed {
            workspaceMutationOperationRecoveryIDsWithUnpromotedText.formUnion(
                operationRecords.map(\.id)
            )
            return
        }
        var recordsByID = Dictionary(
            uniqueKeysWithValues: pendingWorkspaceMutationTextRecoveryRecords.map {
                ($0.id, $0)
            }
        )
        for bundled in operationRecords.flatMap(\.textRecoveryRecords) {
            guard let existing = recordsByID[bundled.id] else {
                recordsByID[bundled.id] = bundled
                continue
            }
            if workspaceMutationTextRecoveryRecord(bundled, isNewerThan: existing) {
                recordsByID[bundled.id] = bundled
            }
        }
        pendingWorkspaceMutationTextRecoveryRecords = recordsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        for operationRecord in operationRecords {
            do {
                try promoteBundledWorkspaceMutationTextRecoveryRecords(
                    operationRecord
                )
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.remove(
                    operationRecord.id
                )
            } catch {
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
                    operationRecord.id
                )
                present(error, title: "Could Not Preserve Recovery Copy")
            }
        }
    }

    func promoteBundledWorkspaceMutationTextRecoveryRecords(
        _ operationRecord: WorkspaceMutationOperationRecoveryRecord
    ) throws {
        guard !workspaceMutationTextRecoveryLoadFailed else {
            throw WorkspaceMutationOperationRecoveryError.textRecoveryUnavailable(
                operationRecord.sourceURL
            )
        }
        let recoveryIDs = Set(operationRecord.textRecoveryRecords.map(\.id))
            .sorted { $0.uuidString < $1.uuidString }
        for recoveryID in recoveryIDs {
            guard let promotedRecord = newestWorkspaceMutationTextRecoveryRecord(
                recoveryID: recoveryID,
                operationRecord: operationRecord
            ) else {
                continue
            }
            try workspaceMutationTextRecoveryStore.upsert(promotedRecord)
        }
    }

    func newestWorkspaceMutationTextRecoveryRecord(
        recoveryID: UUID,
        operationRecord: WorkspaceMutationOperationRecoveryRecord
    ) -> WorkspaceMutationTextRecoveryRecord? {
        var candidates = operationRecord.textRecoveryRecords.filter {
            $0.id == recoveryID
        }
        candidates.append(contentsOf: pendingWorkspaceMutationTextRecoveryRecords.filter {
            $0.id == recoveryID
        })

        var sessions = workspaceMutationManagedSessions()
        sessions.append(contentsOf: workspaceMutationTextRecoverySessions.values)
        var seenSessions: Set<ObjectIdentifier> = []
        for session in sessions
            where seenSessions.insert(ObjectIdentifier(session)).inserted
        {
            let sessionIdentity = ObjectIdentifier(session)
            guard workspaceMutationTextRecoveryContexts[sessionIdentity]?.recoveryID ==
                recoveryID,
                let liveRecord = workspaceMutationTextRecoveryRecord(for: session)
            else {
                continue
            }
            candidates.append(liveRecord)
        }

        return candidates.reduce(nil) { newest, candidate in
            guard let newest else { return candidate }
            return workspaceMutationTextRecoveryRecord(
                newest,
                isNewerThan: candidate
            ) ? newest : candidate
        }
    }

    func workspaceMutationTextRecoveryRecord(
        _ candidate: WorkspaceMutationTextRecoveryRecord,
        isNewerThan existing: WorkspaceMutationTextRecoveryRecord
    ) -> Bool {
        candidate.revision > existing.revision ||
            (candidate.revision == existing.revision &&
                candidate.updatedAt > existing.updatedAt)
    }
}
