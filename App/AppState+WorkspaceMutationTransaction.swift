import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func beginWorkspaceNamespaceMutation(
        _ records: [WorkspaceSessionRelocationRecord]
    ) throws {
        try beginWorkspaceNamespaceMutation(records.map(\.session))
    }

    func beginWorkspaceNamespaceMutation(
        _ sessions: [DocumentSession],
        allowingExistingRecovery: Bool = false
    ) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded()
        if !allowingExistingRecovery,
           let recovery = nextWorkspaceMutationRecovery()
        {
            throw WorkspaceMutationError.indeterminateSession(recovery.sourceURL)
        }
        guard workspaceMutationNamespaceDepth == 0 else {
            throw WorkspaceMutationError.operationAlreadyInProgress
        }
        guard workspaceImageAssetInsertionCount == 0 else {
            throw WorkspaceMutationError.imageInsertionInProgress
        }
        workspaceMutationNamespaceDepth = 1
        workspaceMutationRefreshPending = true
        workspaceMutationExternalRefreshPending = false
        workspaceMutationRefreshRootAuthority = workspaceSearchRootAuthority
        _ = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        var seen: Set<ObjectIdentifier> = []
        for session in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            let sessionIdentity = ObjectIdentifier(session)
            workspaceMutationWriteFences.insert(sessionIdentity)
            cancelAutosave(for: session)
            externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            supersedeExternalResolutionRead(for: session)
            _ = advanceSessionLifecycle(for: session)
            _ = advanceExternalDiskEventGeneration(for: session)
        }
    }

    func endWorkspaceNamespaceMutation(_ records: [WorkspaceSessionRelocationRecord]) {
        endWorkspaceNamespaceMutation(records.map(\.session))
    }

    func endWorkspaceNamespaceMutation(_ sessions: [DocumentSession]) {
        _ = sessions
        precondition(workspaceMutationNamespaceDepth == 1)
        workspaceMutationWriteFences.removeAll()
        workspaceMutationNamespaceDepth = 0
    }

    func drainWorkspaceMutationRefreshIfNeeded() {
        guard workspaceMutationRefreshPending else { return }
        workspaceMutationRefreshPending = false
        let inspectManagedSessions = workspaceMutationExternalRefreshPending
        workspaceMutationExternalRefreshPending = false
        let retainedRootAuthority = workspaceMutationRefreshRootAuthority
        workspaceMutationRefreshRootAuthority = nil
        if let retainedRootAuthority {
            refreshWorkspaceAfterNamespaceMutation(
                using: retainedRootAuthority,
                inspectManagedSessions: inspectManagedSessions
            )
        } else {
            refreshWorkspaceAfterFileSystemChange()
        }
    }

    func prepareWorkspaceRelocationCommit(
        plan: WorkspaceRelocationPlan,
        relocation: WorkspaceItemRelocation
    ) throws -> PreparedWorkspaceRelocationCommit {
        guard relocation.source == plan.source,
              relocation.destination == plan.destination,
              relocation.expectation == plan.expectation
        else {
            throw WorkspaceMutationError.unexpectedDestination(relocation.destination.fileURL)
        }
        var imageAuthorities: [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority] = [:]
        for record in plan.records {
            imageAuthorities[ObjectIdentifier(record.session)] = try
                prepareEditorImageAssetDocumentAuthority(
                    at: record.newLocation,
                    expecting: record.identity
                )
        }
        return PreparedWorkspaceRelocationCommit(imageAuthorities: imageAuthorities)
    }

    // swiftlint:disable:next function_body_length
    func finishWorkspaceRelocation(
        _ outcome: WorkspaceItemMutationOutcome<PreparedWorkspaceRelocationCommit>,
        plan: WorkspaceRelocationPlan,
        recoveryIntent: WorkspaceRelocationRecoveryContext
    ) throws {
        switch outcome {
        case let .notMoved(failure):
            do {
                try ensureWorkspaceMutationRecoveryTextIsDurable(
                    .relocation(recoveryIntent)
                )
            } catch {
                do {
                    try persistWorkspaceMutationRecoveryIntent(
                        .relocation(recoveryIntent)
                    )
                } catch {
                    present(error, title: "Could Not Preserve Workspace Recovery")
                }
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
                    recoveryIntent.id
                )
                var cleanupIntent = recoveryIntent
                cleanupIntent.reason = failure
                installWorkspaceRelocationCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    plan.source.fileURL,
                    failure
                )
            }
            let verifiedIntent: WorkspaceRelocationRecoveryContext
            do {
                verifiedIntent = try workspaceRelocationContextProvingPhaseTarget(
                    recoveryIntent
                )
            } catch {
                var cleanupIntent = recoveryIntent
                cleanupIntent.reason = failure
                installWorkspaceRelocationCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    plan.source.fileURL,
                    failure
                )
            }
            markWorkspaceMutationRecoveryBundledTextCommitted(id: recoveryIntent.id)
            do {
                try removePersistedWorkspaceMutationRecovery(id: recoveryIntent.id)
                clearInstalledWorkspaceMutationRecovery(
                    id: recoveryIntent.id,
                    knownRecovery: .relocation(verifiedIntent)
                )
            } catch {
                var cleanupIntent = verifiedIntent
                cleanupIntent.reason = failure
                installWorkspaceRelocationCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    plan.source.fileURL,
                    failure
                )
            }
            clearResolvedWorkspaceMutationTextRecovery(for: plan.records.map(\.session))
            throw WorkspaceMutationError.operationFailed(failure, plan.source.fileURL)
        case let .movedAndDurable(relocation, preparedCommit):
            guard relocation.source == plan.source,
                  relocation.destination == plan.destination,
                  relocation.expectation == plan.expectation
            else {
                installWorkspaceRelocationRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    actualMovedExpectation: nil
                )
                throw WorkspaceMutationError.unexpectedDestination(relocation.destination.fileURL)
            }
            do {
                try ensureWorkspaceMutationRecoveryTextIsDurable(
                    .relocation(recoveryIntent)
                )
            } catch {
                do {
                    try persistWorkspaceMutationRecoveryIntent(
                        .relocation(recoveryIntent)
                    )
                } catch {
                    present(error, title: "Could Not Preserve Workspace Recovery")
                }
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
                    recoveryIntent.id
                )
                installWorkspaceRelocationRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    actualMovedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    relocation.destination.fileURL,
                    .namespaceChanged
                )
            }
            var committedIntent = recoveryIntent
            committedIntent.sessionCommitState = .committed
            do {
                try persistWorkspaceMutationRecoveryIntent(.relocation(committedIntent))
            } catch {
                installWorkspaceRelocationRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    actualMovedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    relocation.destination.fileURL,
                    .namespaceChanged
                )
            }
            commitWorkspaceSessionRelocations(
                plan.records,
                relocatedSessionPolicy: plan.relocatedSessionPolicy,
                preparedCommit: preparedCommit
            )
            let verifiedCommittedIntent: WorkspaceRelocationRecoveryContext
            do {
                verifiedCommittedIntent = try workspaceRelocationContextProvingPhaseTarget(
                    committedIntent
                )
            } catch {
                var cleanupIntent = committedIntent
                cleanupIntent.reason = .namespaceChanged
                installWorkspaceRelocationCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    relocation.destination.fileURL,
                    .namespaceChanged
                )
            }
            markWorkspaceMutationRecoveryBundledTextCommitted(id: recoveryIntent.id)
            do {
                try removePersistedWorkspaceMutationRecovery(id: recoveryIntent.id)
                clearInstalledWorkspaceMutationRecovery(
                    id: recoveryIntent.id,
                    knownRecovery: .relocation(verifiedCommittedIntent)
                )
            } catch {
                var cleanupIntent = verifiedCommittedIntent
                cleanupIntent.reason = .namespaceChanged
                installWorkspaceRelocationCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    relocation.destination.fileURL,
                    .namespaceChanged
                )
            }
        case let .movedButIndeterminate(indeterminate):
            installWorkspaceRelocationRecovery(
                recoveryIntent,
                reason: indeterminate.reason,
                actualMovedExpectation: indeterminate.actualMovedExpectation
            )
            throw WorkspaceMutationError.indeterminateOperation(
                indeterminate.relocation.destination.fileURL,
                indeterminate.reason
            )
        }
    }

    func workspaceRelocationContextProvingPhaseTarget(
        _ context: WorkspaceRelocationRecoveryContext
    ) throws -> WorkspaceRelocationRecoveryContext {
        let resolved = try resolveRelocationAuthorities(context)
        guard workspaceRelocationPhaseTargetIsProven(resolved.context) else {
            throw WorkspaceMutationError.indeterminateOperation(
                context.destination.fileURL,
                context.reason
            )
        }
        return resolved.context
    }

    func commitWorkspaceSessionRelocations(
        _ records: [WorkspaceSessionRelocationRecord],
        relocatedSessionPolicy: WorkspaceSessionLRUPolicy,
        preparedCommit: PreparedWorkspaceRelocationCommit
    ) {
        removeWorkspaceRelocationSourceState(records)
        sessionPolicy = relocatedSessionPolicy
        for record in records {
            commitWorkspaceSessionRelocation(record, preparedCommit: preparedCommit)
        }
        clearPromptsNotMatchingCurrentDocument()
        restoreRecoveryPrompt(for: currentDocument)
    }

    func removeWorkspaceRelocationSourceState(
        _ records: [WorkspaceSessionRelocationRecord]
    ) {
        for record in records {
            removeExactURLValue(in: &sessionCache, at: record.oldURL)
            removeExactURLValue(in: &retiredEditorDocumentSessions, at: record.oldURL)
            removeExactURLValue(in: &lastKnownDiskHashes, at: record.oldURL)
            removeExactURLValue(in: &lastKnownDiskModificationDates, at: record.oldURL)
            removeExactURLValue(in: &pendingExternalTexts, at: record.oldURL)
            removeExactURLValue(in: &pendingExternalFileVersions, at: record.oldURL)
            removeExactURLValue(in: &deferredExternalChangeResolutions, at: record.oldURL)
            removeExactURLValue(in: &externalResolutionIntentCaptures, at: record.oldURL)
            detachedSessionURLs = Set(detachedSessionURLs.filter {
                !exactFileURLSpellingMatches($0, record.oldURL)
            })
        }
    }

    func commitWorkspaceSessionRelocation(
        _ record: WorkspaceSessionRelocationRecord,
        preparedCommit: PreparedWorkspaceRelocationCommit
    ) {
        let session = record.session
        let sessionIdentity = ObjectIdentifier(session)
        let preparedAuthority = preparedCommit.imageAuthorities[sessionIdentity]
        precondition(preparedAuthority != nil)

        restoreWorkspaceSessionOwners(record)
        restoreWorkspaceRelocationURLState(record, preparedAuthority: preparedAuthority)
        retargetWorkspaceRelocationPrompts(record)

        editorWriterInstallations[sessionIdentity] = nil
        anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
            location: record.newLocation,
            identity: record.identity,
            sha256Digest: record.sha256Digest
        )
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        editorImageAssetDocumentAuthorities[sessionIdentity] = preparedAuthority.map(
            RetainedEditorImageAssetDocumentAuthority.init
        )
        session.relocate(to: record.newURL)
        relocateWorkspaceMutationTextRecovery(for: session, to: record.newURL)
        restoreWorkspaceRelocationResolution(record)
    }

    func restoreWorkspaceSessionOwners(_ record: WorkspaceSessionRelocationRecord) {
        if record.wasCached {
            sessionCache[record.newURL] = record.session
        }
        if let retirement = record.retirement {
            retiredEditorDocumentSessions[record.newURL] = RetiredEditorDocumentSession(
                canonicalURL: record.newURL,
                session: record.session,
                bindingIDs: retirement.bindingIDs,
                awaitingInstallations: retirement.awaitingInstallations,
                securityScopedAuthorityOwners: retirement.securityScopedAuthorityOwners
            )
        }
    }

    func restoreWorkspaceRelocationURLState(
        _ record: WorkspaceSessionRelocationRecord,
        preparedAuthority: PreparedEditorImageAssetDocumentAuthority?
    ) {
        if let knownDiskHash = record.knownDiskHash {
            lastKnownDiskHashes[record.newURL] = knownDiskHash
        }
        if let knownDiskModificationDate = record.knownDiskModificationDate {
            lastKnownDiskModificationDates[record.newURL] = knownDiskModificationDate
        }
        if let pendingExternalText = record.pendingExternalText {
            pendingExternalTexts[record.newURL] = pendingExternalText
        }
        if let observation = record.pendingExternalFileVersion {
            pendingExternalFileVersions[record.newURL] = ObservedRetainedFileVersion(
                location: record.newLocation,
                file: MarkdownFile(
                    url: record.newURL,
                    text: observation.file.text,
                    fileKind: FileKind(url: record.newURL) ?? observation.file.fileKind
                ),
                identity: observation.identity,
                sha256Digest: observation.sha256Digest,
                preparedImageAssetAuthority: preparedAuthority
            )
        }
        if record.wasDetached {
            detachedSessionURLs.insert(record.newURL)
        }
    }

    func retargetWorkspaceRelocationPrompts(_ record: WorkspaceSessionRelocationRecord) {
        if externalChangePrompt.map({
            exactFileURLSpellingMatches($0.fileURL, record.oldURL)
        }) == true {
            externalChangePrompt = ExternalChangePrompt(fileURL: record.newURL)
        }
        if missingFilePrompt.map({
            exactFileURLSpellingMatches($0.fileURL, record.oldURL)
        }) == true {
            missingFilePrompt = MissingFilePrompt(fileURL: record.newURL)
        }
    }

    func restoreWorkspaceRelocationResolution(_ record: WorkspaceSessionRelocationRecord) {
        guard let resolution = record.deferredExternalResolution else { return }
        let session = record.session
        deferredExternalChangeResolutions[record.newURL] = resolution
        externalResolutionIntentCaptures[record.newURL] = ExternalResolutionIntentCapture(
            intent: resolution,
            sourceSnapshot: EditorDocumentSourceSnapshot(
                source: session.text,
                revision: session.version
            ),
            diskEventGeneration: currentExternalDiskEventGeneration(for: session)
        )
    }

    func resumeWorkspaceRelocationWork(
        _ records: [WorkspaceSessionRelocationRecord]
    ) {
        for record in records {
            let session = record.session
            let sessionIdentity = ObjectIdentifier(session)
            guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
                  let stateURL = sessionStateURL(for: session)
            else {
                continue
            }
            if let resolution = exactURLValue(
                in: deferredExternalChangeResolutions,
                at: stateURL
            ) ?? record.deferredExternalResolution {
                externalResolutionIntentCaptures[stateURL] = ExternalResolutionIntentCapture(
                    intent: resolution,
                    sourceSnapshot: EditorDocumentSourceSnapshot(
                        source: session.text,
                        revision: session.version
                    ),
                    diskEventGeneration: currentExternalDiskEventGeneration(for: session)
                )
                restartExternalResolutionIfNeeded(for: session)
            } else if record.hadExternalDiskInspection {
                handleExternalChange(for: session, advancingDiskEvent: false)
            }
            if session.isDirty {
                scheduleAutosave(for: session)
            }
        }
        restoreRecoveryPrompt(for: currentDocument)
    }

    func finishWorkspaceTrash(_ records: [WorkspaceTrashSessionRecord]) {
        var detachedRecords: [WorkspaceTrashSessionRecord] = []
        var removedCurrentSession = false

        for record in records {
            let session = record.session
            let changedDuringTrash = session.version != record.initialVersion
                || session.isDirty
                || hasPendingEditorSource(for: session)
            discardEditorImageAssetDocumentAuthority(for: session)
            if changedDuringTrash {
                do {
                    try persistWorkspaceMutationTextRecovery(for: session)
                } catch {
                    present(error, title: "Could Not Preserve Recovery Copy")
                }
                markSessionDetachedFromMissingFile(session, url: record.oldURL)
                detachedRecords.append(record)
                continue
            }

            _ = clearWorkspaceMutationTextRecovery(for: session)
            removedCurrentSession = removedCurrentSession || session === currentDocument
            discardRetiredEditorDocumentSession(session, canonicalURL: record.oldURL)
            clearSessionState(for: session, fallbackURL: record.oldURL)
        }

        if let currentDetached = detachedRecords.first(where: {
            $0.session === currentDocument
        }) {
            markSessionDetachedFromMissingFile(
                currentDetached.session,
                url: currentDetached.oldURL
            )
        } else if let recovery = detachedRecords.first {
            setCurrentDocument(recovery.session)
            markSessionDetachedFromMissingFile(recovery.session, url: recovery.oldURL)
        } else if removedCurrentSession {
            setCurrentDocument(DocumentSession())
        }
    }

    func resumeWorkspaceTrashWork(
        _ records: [WorkspaceTrashSessionRecord]
    ) {
        for record in records {
            let session = record.session
            let sessionIdentity = ObjectIdentifier(session)
            guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
                  let stateURL = sessionStateURL(for: session),
                  !detachedSessionURLs.contains(where: {
                      exactFileURLSpellingMatches($0, stateURL)
                  })
            else {
                continue
            }
            if let resolution = exactURLValue(
                in: deferredExternalChangeResolutions,
                at: stateURL
            ) ?? record.deferredExternalResolution {
                externalResolutionIntentCaptures[stateURL] = ExternalResolutionIntentCapture(
                    intent: resolution,
                    sourceSnapshot: EditorDocumentSourceSnapshot(
                        source: session.text,
                        revision: session.version
                    ),
                    diskEventGeneration: currentExternalDiskEventGeneration(for: session)
                )
                restartExternalResolutionIfNeeded(for: session)
            } else if record.hadExternalDiskInspection {
                handleExternalChange(for: session, advancingDiskEvent: false)
            }
            if session.isDirty {
                scheduleAutosave(for: session)
            }
            finishRetiredEditorDocumentSessionIfPossible(for: session)
        }
        restoreRecoveryPrompt(for: currentDocument)
    }

    func recordWorkspaceTrashCleanupState(
        _ cleanupState: WorkspaceTrashStagingCleanupState
    ) {
        guard case let .removalIndeterminate(location) = cleanupState else { return }
        if !workspaceTrashCleanupNotices.contains(where: {
            $0.stagingLocation == location
        }) {
            workspaceTrashCleanupNotices.append(
                WorkspaceTrashCleanupNotice(stagingLocation: location)
            )
        }
        present(
            WorkspaceMutationError.trashStagingCleanupRequired(location.fileURL),
            title: "Trash Cleanup Needs Attention"
        )
    }
}
