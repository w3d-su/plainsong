import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

private struct ExternalResolutionReadContext {
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let token: UUID
    let generation: UInt64
    let lifecycleGeneration: UInt64
    let intent: DeferredExternalChangeResolution
}

@MainActor
extension AppState {
    func isExternalSourceMutationFenced(for session: DocumentSession) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        if externalReloadTasks[sessionIdentity] != nil ||
            pendingExternalReloadApplications[sessionIdentity] != nil
        {
            return true
        }
        guard let stateURL = sessionStateURL(for: session) else { return false }
        return deferredExternalChangeResolutions[stateURL] != nil
    }

    func canPublishEditorSourceDuringExternalResolution(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession
    ) -> Bool {
        guard isExternalSourceMutationFenced(for: session) else { return true }
        let sessionIdentity = ObjectIdentifier(session)
        guard externalReloadTasks[sessionIdentity] == nil,
              pendingExternalReloadApplications[sessionIdentity] == nil
        else {
            return false
        }
        return pendingEditorSourceInstallations[installation] === session
    }

    func reloadExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL
        let session = currentDocument
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, key)
        else {
            externalChangePrompt = nil
            return
        }
        guard pendingExternalTexts[key] != nil || pendingExternalFileVersions[key] != nil else {
            externalChangePrompt = nil
            return
        }

        externalDiskInspectionTasks.removeValue(forKey: ObjectIdentifier(session))?.task.cancel()
        deferredExternalChangeResolutions[key] = .reload
        externalResolutionIntentCaptures[key] = ExternalResolutionIntentCapture(
            intent: .reload,
            sourceSnapshot: EditorDocumentSourceSnapshot(
                source: session.text,
                revision: session.version
            ),
            diskEventGeneration: currentExternalDiskEventGeneration(for: session)
        )
        cancelAutosave(for: session)
        if hasPendingEditorSource(for: session) {
            return
        }
        supersedeExternalResolutionRead(for: session)
        startExternalResolutionRead(for: session, canonicalURL: key, intent: .reload)
    }

    func keepMineForExternallyChangedFile() {
        guard let prompt = externalChangePrompt else { return }
        let key = prompt.fileURL
        let session = currentDocument
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, key)
        else {
            externalChangePrompt = nil
            return
        }
        guard pendingExternalTexts[key] != nil || pendingExternalFileVersions[key] != nil else {
            externalChangePrompt = nil
            return
        }

        externalDiskInspectionTasks.removeValue(forKey: ObjectIdentifier(session))?.task.cancel()
        deferredExternalChangeResolutions[key] = .keepMine
        externalResolutionIntentCaptures[key] = ExternalResolutionIntentCapture(
            intent: .keepMine,
            sourceSnapshot: EditorDocumentSourceSnapshot(
                source: session.text,
                revision: session.version
            ),
            diskEventGeneration: currentExternalDiskEventGeneration(for: session)
        )
        cancelAutosave(for: session)
        supersedeExternalResolutionRead(for: session)
        if hasPendingEditorSource(for: session) {
            return
        }
        startExternalResolutionRead(for: session, canonicalURL: key, intent: .keepMine)
    }

    func resolveDeferredExternalChangeIfPossible(for session: DocumentSession) {
        guard !hasPendingEditorSource(for: session),
              let url = sessionStateURL(for: session),
              let resolution = deferredExternalChangeResolutions[url]
        else {
            return
        }
        startExternalResolutionRead(for: session, canonicalURL: url, intent: resolution)
    }

    func restartExternalResolutionIfNeeded(for session: DocumentSession) {
        guard !hasPendingEditorSource(for: session),
              let stateURL = sessionStateURL(for: session),
              let intent = deferredExternalChangeResolutions[stateURL]
        else {
            return
        }
        startExternalResolutionRead(
            for: session,
            canonicalURL: stateURL,
            intent: intent
        )
    }

    func synchronizePendingExternalReloadIfPossible(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard var application = pendingExternalReloadApplications[sessionIdentity],
              application.session === session,
              let operation = externalReloadTasks[sessionIdentity],
              operation.token == application.token,
              operation.generation == application.generation,
              session.version == application.acceptedSourceSnapshot.revision
        else {
            if pendingExternalReloadApplications[sessionIdentity]?.session === session {
                abortExternalResolutionAfterUnexpectedSourceChange(for: session)
            }
            return
        }

        let liveInstallations = liveEditorDocumentBindingInstallations(for: session)
        application.synchronizedInstallations.formIntersection(liveInstallations)

        for installation in liveInstallations
            where !application.synchronizedInstallations.contains(installation)
        {
            guard editorBindingInstallations[installation] === session,
                  let synchronize = editorDocumentSourceSynchronizers[installation],
                  synchronize(application.acceptedSourceSnapshot)
            else {
                continue
            }
            application.synchronizedInstallations.insert(installation)
        }
        pendingExternalReloadApplications[sessionIdentity] = application

        let remainingInstallations = liveEditorDocumentBindingInstallations(for: session)
        guard remainingInstallations.isSubset(of: application.synchronizedInstallations) else {
            return
        }
        switch application.intent {
        case .reload:
            finalizeAppliedExternalReload(application)
        case .keepMine:
            finalizeKeepMineResolution(application)
        }
    }

    func handleCurrentDocumentExternalChange() {
        handleExternalChange(for: currentDocument)
    }

    func handleExternalChange(
        for session: DocumentSession,
        advancingDiskEvent: Bool = true
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        if indeterminateSessionWrites[sessionIdentity] != nil {
            refreshIndeterminateFileWriteReconciliation(for: session)
            return
        }
        guard let stateURL = sessionStateURL(for: session) else { return }
        guard let location = retainedManagedSessionLocation(for: session),
              exactFileURLSpellingMatches(location.fileURL, stateURL)
        else {
            guard !FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) else {
                return
            }
            markSessionDetachedFromMissingFile(session, url: stateURL)
            return
        }

        let diskEventGeneration = advancingDiskEvent
            ? advanceExternalDiskEventGeneration(for: session)
            : currentExternalDiskEventGeneration(for: session)
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        if let intent = deferredExternalChangeResolutions[stateURL] {
            guard refreshExternalResolutionIntentCapture(
                for: session,
                canonicalURL: stateURL,
                intent: intent,
                diskEventGeneration: diskEventGeneration
            ) else { return }
            restartExternalResolutionIfNeeded(for: session)
            if session === currentDocument {
                restoreRecoveryPrompt(for: session)
            }
            return
        }

        let token = UUID()
        let lifecycleGeneration = currentSessionLifecycleGeneration(for: session)
        let sourceSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        let reader = coherentFileReader
        let applicationPreparer = externalReloadApplicationPreparer
        let task = Task { @MainActor [weak self, weak session] in
            let outcome = await reader.readCoherentFile(at: location)
            guard !Task.isCancelled else { return }
            let payload: ExternalReloadApplicationPayload? = switch outcome {
            case let .loaded(snapshot):
                await applicationPreparer.prepare(
                    snapshot: snapshot,
                    sourceSnapshot: sourceSnapshot
                )
            case .missing, .symbolicLink, .notRegularFile, .unreadable, .invalidUTF8,
                 .namespaceChanged, .unstable, .cancelled:
                nil
            }
            guard !Task.isCancelled, let self, let session else { return }
            handleExternalDiskInspection(
                outcome,
                payload: payload,
                session: session,
                canonicalURL: stateURL,
                location: location,
                token: token,
                lifecycleGeneration: lifecycleGeneration,
                diskEventGeneration: diskEventGeneration
            )
        }
        externalDiskInspectionTasks[sessionIdentity] = ExternalDiskInspectionTask(
            token: token,
            session: session,
            canonicalURL: stateURL,
            location: location,
            lifecycleGeneration: lifecycleGeneration,
            diskEventGeneration: diskEventGeneration,
            sourceSnapshot: sourceSnapshot,
            task: task
        )
    }

    func recordKnownDiskText(_ text: String, for url: URL, modificationDate: Date? = nil) {
        lastKnownDiskHashes[url] = Self.contentHash(text)
        recordKnownDiskModificationDate(
            modificationDate ?? Self.contentModificationDate(for: url),
            for: url
        )
    }

    func clearSessionState(
        for session: DocumentSession,
        fallbackURL: URL? = nil,
        removesEditorBindingRegistration: Bool = true
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        var stateKeys = Set(sessionCache.compactMap { key, cachedSession in
            cachedSession === session ? key : nil
        })
        if let stateURL = sessionStateURL(for: session) {
            stateKeys.insert(stateURL)
        }
        if let fallbackURL {
            stateKeys.insert(fallbackURL)
        }

        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        cancelAutosave(for: session)
        cancelStatisticsRefresh(for: session)
        if removesEditorBindingRegistration {
            removeEditorDocumentBindingRegistration(for: session)
        }
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        externalDiskEventGenerations[sessionIdentity] = nil

        for key in stateKeys {
            if sessionCache[key] === session {
                sessionCache[key] = nil
            }
            sessionPolicy.remove(key)
            lastKnownDiskHashes[key] = nil
            lastKnownDiskModificationDates[key] = nil
            clearExternalChangeConflict(at: key)
            deferredExternalChangeResolutions[key] = nil
            externalResolutionIntentCaptures[key] = nil
            detachedSessionURLs.remove(key)
            if let prompt = externalChangePrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                externalChangePrompt = nil
            }
            if let prompt = missingFilePrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                missingFilePrompt = nil
            }
            if let prompt = indeterminateFileWriteReconciliationPrompt,
               exactFileURLSpellingMatches(prompt.fileURL, key)
            {
                indeterminateFileWriteReconciliationPrompt = nil
            }
        }
    }

    func markSessionDetachedFromMissingFile(_ session: DocumentSession, url: URL) {
        let sessionIdentity = ObjectIdentifier(session)
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        detachedSessionURLs.insert(url)
        clearExternalChangeConflict(at: url)
        deferredExternalChangeResolutions[url] = nil
        externalResolutionIntentCaptures[url] = nil
        lastKnownDiskHashes[url] = nil
        lastKnownDiskModificationDates[url] = nil
        sessionPolicy.updateDirtyState(for: url, isDirty: true)
        cancelAutosave(for: session)

        if !session.isDirty {
            session.reset(
                text: session.text,
                url: session.fileURL,
                fileKind: session.fileKind,
                isDirty: true
            )
        }

        guard session === currentDocument else { return }
        restoreRecoveryPrompt(for: session)
    }

    nonisolated static func contentHash(_ text: String) -> String {
        WorkspaceSearchContentFingerprint(text: text).sha256Digest
    }

    static func contentModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func modificationDate(from metadata: WorkspaceCoherentFileMetadata) -> Date {
        Date(
            timeIntervalSince1970: Double(metadata.modificationSeconds) +
                Double(metadata.modificationNanoseconds) / 1_000_000_000
        )
    }

    func currentExternalDiskEventGeneration(for session: DocumentSession) -> UInt64 {
        externalDiskEventGenerations[ObjectIdentifier(session), default: 0]
    }

    @discardableResult
    func advanceExternalDiskEventGeneration(for session: DocumentSession) -> UInt64 {
        let identity = ObjectIdentifier(session)
        precondition(
            externalDiskEventGenerations[identity, default: 0] < .max,
            "External disk-event generation exhausted"
        )
        externalDiskEventGenerations[identity, default: 0] += 1
        return externalDiskEventGenerations[identity, default: 0]
    }
}

@MainActor
private extension AppState {
    func startExternalResolutionRead(
        for session: DocumentSession,
        canonicalURL: URL,
        intent: DeferredExternalChangeResolution
    ) {
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, canonicalURL),
              let location = retainedManagedSessionLocation(for: session),
              exactFileURLSpellingMatches(location.fileURL, canonicalURL),
              deferredExternalChangeResolutions[canonicalURL] == intent
        else {
            return
        }

        guard let intentCapture = externalResolutionIntentCaptures[canonicalURL],
              intentCapture.intent == intent,
              intentCapture.sourceSnapshot.revision == session.version,
              intentCapture.diskEventGeneration == currentExternalDiskEventGeneration(for: session)
        else {
            abortExternalResolutionAfterUnexpectedSourceChange(for: session)
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        let lifecycleGeneration = currentSessionLifecycleGeneration(for: session)
        let sourceSnapshot = intentCapture.sourceSnapshot
        let diskEventGeneration = intentCapture.diskEventGeneration
        if let existing = externalReloadTasks[sessionIdentity],
           existing.session === session,
           exactFileURLSpellingMatches(existing.canonicalURL, canonicalURL),
           existing.location == location,
           existing.lifecycleGeneration == lifecycleGeneration,
           existing.sourceSnapshot.revision == sourceSnapshot.revision,
           existing.diskEventGeneration == diskEventGeneration,
           existing.intent == intent
        {
            return
        }
        supersedeExternalResolutionRead(for: session)
        nextExternalReloadGeneration += 1
        let generation = nextExternalReloadGeneration
        let token = UUID()
        let reader = coherentFileReader
        let applicationPreparer = externalReloadApplicationPreparer
        let completionContext = ExternalResolutionReadContext(
            canonicalURL: canonicalURL,
            location: location,
            token: token,
            generation: generation,
            lifecycleGeneration: lifecycleGeneration,
            intent: intent
        )
        let task = Task { @MainActor [weak self, weak session] in
            let outcome = await reader.readCoherentFile(at: location)
            guard !Task.isCancelled else { return }
            let payload: ExternalReloadApplicationPayload? = switch outcome {
            case let .loaded(snapshot):
                await applicationPreparer.prepare(
                    snapshot: snapshot,
                    sourceSnapshot: sourceSnapshot
                )
            case .missing, .symbolicLink, .notRegularFile, .unreadable, .invalidUTF8,
                 .namespaceChanged, .unstable, .cancelled:
                nil
            }
            guard !Task.isCancelled, let self, let session else { return }
            handleExternalResolutionRead(
                outcome,
                payload: payload,
                session: session,
                context: completionContext
            )
        }
        externalReloadTasks[sessionIdentity] = ExternalReloadTask(
            token: token,
            generation: generation,
            session: session,
            canonicalURL: canonicalURL,
            location: location,
            lifecycleGeneration: lifecycleGeneration,
            sourceSnapshot: sourceSnapshot,
            diskEventGeneration: diskEventGeneration,
            intent: intent,
            task: task
        )
    }

    func handleExternalResolutionRead(
        _ outcome: WorkspaceCoherentFileReadOutcome,
        payload: ExternalReloadApplicationPayload?,
        session: DocumentSession,
        context: ExternalResolutionReadContext
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard let operation = externalReloadTasks[sessionIdentity],
              operation.token == context.token,
              operation.generation == context.generation
        else {
            return
        }
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, context.canonicalURL),
              retainedManagedSessionLocation(for: session) == context.location,
              currentSessionLifecycleGeneration(for: session) == context.lifecycleGeneration,
              operation.sourceSnapshot.revision == session.version,
              operation.diskEventGeneration == currentExternalDiskEventGeneration(for: session),
              let intentCapture = externalResolutionIntentCaptures[context.canonicalURL],
              intentCapture.intent == context.intent,
              intentCapture.sourceSnapshot.revision == operation.sourceSnapshot.revision,
              intentCapture.diskEventGeneration == operation.diskEventGeneration,
              deferredExternalChangeResolutions[context.canonicalURL] == context.intent,
              isAddressableExternalResolutionSession(
                  session,
                  canonicalURL: context.canonicalURL
              )
        else {
            externalReloadTasks[sessionIdentity] = nil
            restartExternalResolutionIfNeeded(for: session)
            return
        }
        guard !hasPendingEditorSource(for: session) else {
            externalReloadTasks[sessionIdentity] = nil
            return
        }

        switch outcome {
        case let .loaded(snapshot):
            guard let payload,
                  payload.snapshot.metadata == snapshot.metadata,
                  payload.snapshot.sha256Digest == snapshot.sha256Digest,
                  payload.snapshot.exactBytes.count == snapshot.exactBytes.count,
                  !hasConflictingPhysicalSessionOwnership(
                      snapshot.metadata.identity,
                      excluding: session
                  )
            else {
                externalReloadTasks[sessionIdentity] = nil
                markSessionDetachedFromMissingFile(session, url: context.canonicalURL)
                return
            }
            switch context.intent {
            case .reload:
                applyExternalReloadSnapshot(
                    payload,
                    session: session,
                    canonicalURL: context.canonicalURL,
                    token: context.token,
                    generation: context.generation
                )
            case .keepMine:
                prepareKeepMineResolution(
                    payload,
                    session: session,
                    canonicalURL: context.canonicalURL,
                    token: context.token,
                    generation: context.generation
                )
            }
        case .missing, .symbolicLink, .notRegularFile, .unreadable, .invalidUTF8,
             .namespaceChanged, .unstable:
            externalReloadTasks[sessionIdentity] = nil
            markSessionDetachedFromMissingFile(session, url: context.canonicalURL)
        case .cancelled:
            externalReloadTasks[sessionIdentity] = nil
            restartExternalResolutionIfNeeded(for: session)
        }
    }

    func applyExternalReloadSnapshot(
        _ payload: ExternalReloadApplicationPayload,
        session: DocumentSession,
        canonicalURL: URL,
        token: UUID,
        generation: UInt64
    ) {
        guard let fileKind = FileKind(url: canonicalURL) else {
            externalReloadTasks[ObjectIdentifier(session)] = nil
            markSessionDetachedFromMissingFile(session, url: canonicalURL)
            return
        }

        editorWriterInstallations[ObjectIdentifier(session)] = nil
        guard session.reset(
            precomputedTextTransition: payload.textTransition,
            url: canonicalURL,
            fileKind: fileKind,
            isDirty: false
        ) else {
            abortExternalResolutionAfterUnexpectedSourceChange(for: session)
            return
        }
        let acceptedSourceSnapshot = EditorDocumentSourceSnapshot(
            source: payload.snapshot.text,
            revision: session.version
        )
        pendingExternalReloadApplications[ObjectIdentifier(session)] = PendingExternalReloadApplication(
            token: token,
            generation: generation,
            session: session,
            canonicalURL: canonicalURL,
            payload: payload,
            acceptedSourceSnapshot: acceptedSourceSnapshot,
            intent: .reload,
            synchronizedInstallations: []
        )
        synchronizePendingExternalReloadIfPossible(for: session)
    }

    func finalizeAppliedExternalReload(_ application: PendingExternalReloadApplication) {
        let session = application.session
        let sessionIdentity = ObjectIdentifier(session)
        guard let operation = externalReloadTasks[sessionIdentity],
              operation.token == application.token,
              operation.generation == application.generation,
              deferredExternalChangeResolutions[application.canonicalURL] == .reload,
              let observation = externalObservation(
                  from: application.payload,
                  location: operation.location,
                  canonicalURL: application.canonicalURL
              ),
              adoptObservedRetainedFileVersion(observation, for: session)
        else {
            markSessionDetachedFromMissingFile(session, url: application.canonicalURL)
            return
        }

        clearAcceptedExternalResolution(
            application,
            observation: observation,
            session: session
        )
        sessionPolicy.updateDirtyState(for: application.canonicalURL, isDirty: false)
        cancelAutosave(for: session)
        if session === currentDocument {
            scheduleCompletionWorkspaceRefresh()
            restartActiveWorkspaceSearchWithFreshOverlays()
        }
        finishRetiredEditorDocumentSessionIfPossible(for: session)
    }

    func prepareKeepMineResolution(
        _ payload: ExternalReloadApplicationPayload,
        session: DocumentSession,
        canonicalURL: URL,
        token: UUID,
        generation: UInt64
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard let operation = externalReloadTasks[sessionIdentity],
              operation.token == token,
              operation.generation == generation,
              operation.sourceSnapshot.revision == session.version,
              deferredExternalChangeResolutions[canonicalURL] == .keepMine
        else {
            return
        }

        pendingExternalReloadApplications[sessionIdentity] = PendingExternalReloadApplication(
            token: token,
            generation: generation,
            session: session,
            canonicalURL: canonicalURL,
            payload: payload,
            acceptedSourceSnapshot: operation.sourceSnapshot,
            intent: .keepMine,
            synchronizedInstallations: []
        )
        synchronizePendingExternalReloadIfPossible(for: session)
    }

    func finalizeKeepMineResolution(_ application: PendingExternalReloadApplication) {
        let session = application.session
        let sessionIdentity = ObjectIdentifier(session)
        guard let operation = externalReloadTasks[sessionIdentity],
              operation.token == application.token,
              operation.generation == application.generation,
              deferredExternalChangeResolutions[application.canonicalURL] == .keepMine,
              session.version == application.acceptedSourceSnapshot.revision,
              let observation = externalObservation(
                  from: application.payload,
                  location: operation.location,
                  canonicalURL: application.canonicalURL
              ),
              adoptObservedRetainedFileVersion(observation, for: session)
        else {
            markSessionDetachedFromMissingFile(session, url: application.canonicalURL)
            return
        }

        session.rebaseSavedText(to: observation.file.text)
        clearAcceptedExternalResolution(
            application,
            observation: observation,
            session: session
        )
        sessionPolicy.updateDirtyState(
            for: application.canonicalURL,
            isDirty: session.isDirty
        )
        scheduleAutosave(for: session)
        finishRetiredEditorDocumentSessionIfPossible(for: session)
    }

    func clearAcceptedExternalResolution(
        _ application: PendingExternalReloadApplication,
        observation: ObservedRetainedFileVersion,
        session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        recordKnownSessionDiskText(
            observation.file.text,
            for: session,
            canonicalURL: application.canonicalURL
        )
        clearExternalChangeConflict(at: application.canonicalURL)
        deferredExternalChangeResolutions[application.canonicalURL] = nil
        externalResolutionIntentCaptures[application.canonicalURL] = nil
        detachedSessionURLs.remove(application.canonicalURL)
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        pendingExternalReloadApplications[sessionIdentity] = nil
        externalReloadTasks[sessionIdentity] = nil
        if let prompt = missingFilePrompt,
           exactFileURLSpellingMatches(prompt.fileURL, application.canonicalURL)
        {
            missingFilePrompt = nil
        }
        if let prompt = indeterminateFileWriteReconciliationPrompt,
           exactFileURLSpellingMatches(prompt.fileURL, application.canonicalURL)
        {
            indeterminateFileWriteReconciliationPrompt = nil
        }
        clearExternalChangePromptIfOwned(
            by: session,
            canonicalURL: application.canonicalURL
        )
    }

    func clearExternalChangePromptIfOwned(
        by session: DocumentSession,
        canonicalURL: URL
    ) {
        guard currentDocument === session,
              let prompt = externalChangePrompt,
              exactFileURLSpellingMatches(prompt.fileURL, canonicalURL)
        else {
            return
        }
        externalChangePrompt = nil
    }

    func isAddressableExternalResolutionSession(
        _ session: DocumentSession,
        canonicalURL: URL
    ) -> Bool {
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, canonicalURL)
        else {
            return false
        }
        return session === currentDocument ||
            sessionCache.values.contains(where: { $0 === session }) ||
            retiredEditorDocumentSessions.values.contains(where: { $0.session === session }) ||
            editorDocumentBindingSessions.values.contains(where: { $0 === session }) ||
            editorBindingInstallations.values.contains(where: { $0 === session })
    }

    func handleExternalDiskInspection(
        _ outcome: WorkspaceCoherentFileReadOutcome,
        payload: ExternalReloadApplicationPayload?,
        session: DocumentSession,
        canonicalURL: URL,
        location: WorkspaceFileSystemLocation,
        token: UUID,
        lifecycleGeneration: UInt64,
        diskEventGeneration: UInt64
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard let inspection = externalDiskInspectionTasks[sessionIdentity],
              inspection.token == token,
              inspection.session === session,
              exactFileURLSpellingMatches(inspection.canonicalURL, canonicalURL),
              inspection.location == location,
              inspection.lifecycleGeneration == lifecycleGeneration,
              inspection.diskEventGeneration == diskEventGeneration
        else {
            return
        }
        guard let stateURL = sessionStateURL(for: session),
              exactFileURLSpellingMatches(stateURL, canonicalURL),
              retainedManagedSessionLocation(for: session) == location,
              currentSessionLifecycleGeneration(for: session) == lifecycleGeneration,
              currentExternalDiskEventGeneration(for: session) == diskEventGeneration,
              isAddressableExternalResolutionSession(session, canonicalURL: canonicalURL)
        else {
            externalDiskInspectionTasks[sessionIdentity] = nil
            finishRetiredEditorDocumentSessionIfPossible(for: session)
            return
        }
        externalDiskInspectionTasks[sessionIdentity] = nil
        defer {
            finishRetiredEditorDocumentSessionIfPossible(for: session)
            if session.isDirty, canAutosave(session: session) {
                scheduleAutosave(for: session)
            }
        }

        switch outcome {
        case let .loaded(snapshot):
            guard let payload,
                  payload.snapshot.metadata == snapshot.metadata,
                  payload.snapshot.sha256Digest == snapshot.sha256Digest,
                  payload.snapshot.exactBytes.count == snapshot.exactBytes.count
            else {
                handleExternalChange(for: session, advancingDiskEvent: false)
                return
            }
            applyExternalDiskInspection(
                payload,
                sourceSnapshot: inspection.sourceSnapshot,
                session: session,
                canonicalURL: canonicalURL,
                location: location
            )
        case .missing, .symbolicLink, .notRegularFile, .unreadable, .invalidUTF8,
             .namespaceChanged, .unstable:
            markSessionDetachedFromMissingFile(session, url: canonicalURL)
        case .cancelled:
            break
        }
    }

    func applyExternalDiskInspection(
        _ payload: ExternalReloadApplicationPayload,
        sourceSnapshot: EditorDocumentSourceSnapshot,
        session: DocumentSession,
        canonicalURL: URL,
        location: WorkspaceFileSystemLocation
    ) {
        guard let observation = externalObservation(
            from: payload,
            location: location,
            canonicalURL: canonicalURL
        ) else {
            markSessionDetachedFromMissingFile(session, url: canonicalURL)
            return
        }
        guard !hasConflictingPhysicalSessionOwnership(
            observation.identity,
            excluding: session
        ) else {
            markSessionDetachedFromMissingFile(session, url: canonicalURL)
            return
        }

        let changed = observedRetainedFileVersionDiffers(observation, for: session)
        let hasConflict = pendingExternalTexts[canonicalURL] != nil ||
            pendingExternalFileVersions[canonicalURL] != nil
        if !changed, !hasConflict, !detachedSessionURLs.contains(canonicalURL) {
            recordKnownSessionDiskText(
                observation.file.text,
                for: session,
                canonicalURL: canonicalURL
            )
            return
        }

        if detachedSessionURLs.contains(canonicalURL) ||
            session.isDirty ||
            hasPendingEditorSource(for: session) ||
            session.version != sourceSnapshot.revision
        {
            recordExternalChangeConflict(
                observation,
                for: session,
                canonicalURL: canonicalURL
            )
            return
        }

        guard adoptObservedRetainedFileVersion(observation, for: session),
              session.reset(
                  precomputedTextTransition: payload.textTransition,
                  url: canonicalURL,
                  fileKind: observation.file.fileKind,
                  isDirty: false
              )
        else {
            recordExternalChangeConflict(
                observation,
                for: session,
                canonicalURL: canonicalURL
            )
            return
        }

        clearExternalChangeConflict(at: canonicalURL)
        detachedSessionURLs.remove(canonicalURL)
        recordKnownSessionDiskText(
            observation.file.text,
            for: session,
            canonicalURL: canonicalURL
        )
        sessionPolicy.updateDirtyState(for: canonicalURL, isDirty: false)
        if session === currentDocument {
            missingFilePrompt = nil
            externalChangePrompt = nil
            scheduleCompletionWorkspaceRefresh()
            restartActiveWorkspaceSearchWithFreshOverlays()
        }
    }

    func externalObservation(
        from payload: ExternalReloadApplicationPayload,
        location: WorkspaceFileSystemLocation,
        canonicalURL: URL
    ) -> ObservedRetainedFileVersion? {
        guard let fileKind = FileKind(url: canonicalURL) else { return nil }
        return ObservedRetainedFileVersion(
            location: location,
            file: MarkdownFile(
                url: canonicalURL,
                text: payload.snapshot.text,
                fileKind: fileKind
            ),
            identity: payload.snapshot.metadata.identity,
            sha256Digest: payload.snapshot.sha256Digest
        )
    }

    func recordKnownDiskModificationDate(_ modificationDate: Date?, for url: URL) {
        if let modificationDate {
            lastKnownDiskModificationDates[url] = modificationDate
        } else {
            lastKnownDiskModificationDates[url] = nil
        }
    }
}
