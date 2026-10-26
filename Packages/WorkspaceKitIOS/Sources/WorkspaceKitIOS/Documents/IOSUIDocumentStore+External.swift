import Foundation
import MarkdownCore
import WorkspaceCore

extension IOSUIDocumentStore {
    func handleFileEvent(_ event: IOSDocumentFileEvent, entry: IOSDocumentEntry) {
        guard !entry.superseded, !entry.closed else { return }
        switch event {
        case .externalChange:
            if entry.isClosing || entry.portClosed {
                // A notice does not authorize a read concurrent with provider close.
                // Keep an independent barrier until close or its retained entry reads it.
                entry.hasDeferredExternalChange = true
                entry.autosaveTask?.cancel()
                refreshWritableState(entry)
            } else {
                startExternalRead(entry)
            }
        case .deleted:
            fenceUnavailable(entry, .access(.notFound))
        case .becameReadOnly:
            entry.allowsProviderWrite = false
            if entry.session != nil, !entry.fenced {
                setState(.ready(canWrite: false, accessGeneration: entry.accessGeneration), entry: entry)
            }
        case .downloading:
            fenceUnavailable(entry, .access(.downloading))
        case .offline:
            fenceUnavailable(entry, .access(.offline))
        case .unexpectedRelocation:
            fenceUnavailable(entry, .documentChanged)
        }
    }

    func fenceUnavailable(_ entry: IOSDocumentEntry, _ reason: IOSDocumentFailure) {
        entry.fenced = true
        entry.allowsProviderWrite = false
        entry.autosaveTask?.cancel()
        setState(.unavailable(accessGeneration: entry.accessGeneration, reason: reason), entry: entry)
    }

    func startExternalRead(_ entry: IOSDocumentEntry, allowsClosingObservation: Bool = false) {
        guard !entry.isRetiring, !entry.portClosed, entry.session != nil,
              !entry.isClosing || allowsClosingObservation,
              guardCurrentAuthority(entry, generation: entry.accessGeneration)
        else { return }
        let token = UUID()
        entry.externalToken = token
        entry.hasDeferredExternalChange = false
        entry.pendingProposal = nil
        entry.autosaveTask?.cancel()
        refreshWritableState(entry)
        let capturedVersion = entry.session?.version ?? 0
        let generation = entry.accessGeneration
        let identity = entry.identity
        let location = entry.location
        let lease = entry.lease
        let operationID = UUID()
        let task = Task { @MainActor in
            defer { entry.externalReadTasks[token] = nil }
            do {
                // An already-issued provider write must finish before its own notice is read.
                await entry.queue.drain()
                guard entry.externalToken == token,
                      self.guardCurrentAuthority(entry, generation: generation)
                else { return }
                let read = try await self.coordinatedAccess.read(
                    location,
                    lease: lease,
                    operationID: operationID,
                    maximumByteCount: self.maximumExternalBytes
                )
                await self.completeExternalRead(
                    entry: entry,
                    token: token,
                    capturedVersion: capturedVersion,
                    generation: generation,
                    identity: identity,
                    read: read
                )
            } catch {
                await self.failExternalRead(entry: entry, token: token, error: error)
            }
        }
        entry.externalReadTasks[token] = task
    }

    func completeExternalRead(
        entry: IOSDocumentEntry,
        token: UUID,
        capturedVersion: Int,
        generation: UInt64,
        identity: IOSDocumentIdentity,
        read: IOSCoordinatedRead
    ) async {
        guard entry.externalToken == token, entry.identity == identity else { return }
        guard guardCurrentAuthority(entry, generation: generation) else { return }
        guard let externalText = IOSDocumentTextCodec.decode(read.data) else {
            await failExternalRead(entry: entry, token: token, error: IOSDocumentFailure.access(.unsupportedType))
            return
        }
        if matchesSelfWrite(entry, externalText) {
            finishExternalObservation(entry, token: token)
            return
        }
        guard let session = entry.session else { return }
        if ExactSourceText.matches(externalText, session.text), !session.isDirty {
            finishExternalObservation(entry, token: token)
            return
        }
        if session.version != capturedVersion || session.isDirty || entry.fenced {
            if session.isDirty || entry.fenced {
                entry.externalToken = nil
                await beginConflict(entry, reason: .externalConflict, allowRetry: true)
            } else {
                // Close cannot prove this newer clean revision from the old read.
                // Retain its opaque token instead of issuing a retry during close.
                if entry.isClosing {
                    entry.hasDeferredExternalChange = true
                    return
                }
                // An edit followed by Undo can be clean at a newer revision. Observe afresh.
                startExternalRead(entry)
            }
            return
        }
        entry.externalToken = nil
        publishReloadProposal(entry, text: externalText, fileURL: read.location.fileURL)
    }

    func matchesSelfWrite(_ entry: IOSDocumentEntry, _ externalText: String) -> Bool {
        if let inFlight = entry.inFlightText, ExactSourceText.matches(inFlight, externalText) {
            return true
        }
        if let persisted = entry.lastPersistedText, ExactSourceText.matches(persisted, externalText) {
            return true
        }
        return false
    }

    func finishExternalObservation(_ entry: IOSDocumentEntry, token: UUID) {
        guard entry.externalToken == token else { return }
        entry.externalToken = nil
        refreshWritableState(entry)
        if entry.session?.isDirty == true, !writeBarrier(entry) {
            scheduleAutosave(entry)
        }
    }

    func failExternalRead(entry: IOSDocumentEntry, token: UUID, error: Error) async {
        guard entry.externalToken == token,
              guardCurrentAuthority(entry, generation: entry.accessGeneration)
        else { return }
        let failure = (mapped(error) as? IOSDocumentFailure) ?? .unavailable
        // Unknown external bytes are not permission to resume overwriting the original.
        entry.fenced = true
        entry.externalToken = nil
        entry.autosaveTask?.cancel()
        if entry.session?.isDirty == true {
            do {
                _ = try await persistStableRecovery(entry, reason: .externalConflict)
            } catch {
                publishRecoveryFailure(entry, operationID: UUID())
                return
            }
        }
        guard guardCurrentAuthority(entry, generation: entry.accessGeneration) else { return }
        setState(.unavailable(accessGeneration: entry.accessGeneration, reason: failure), entry: entry)
        emit(.failed(entry.identity, operationID: UUID(), reason: failure))
    }

    func publishReloadProposal(_ entry: IOSDocumentEntry, text: String, fileURL: URL) {
        guard let session = entry.session else { return }
        let fileKind = FileKind(url: fileURL) ?? session.fileKind
        let proposal = IOSDocumentReloadProposal(
            operationID: UUID(),
            capturedRevision: IOSDocumentRevision(documentID: entry.identity, version: session.version),
            accessGeneration: entry.accessGeneration,
            text: text,
            fileURL: fileURL,
            fileKind: fileKind,
            statistics: TextStatistics(text: text)
        )
        entry.pendingProposal = proposal
        refreshWritableState(entry)
        // Close drains reads to prove the current buffer safe to retire. A native
        // editor would dirty that buffer before its closing acknowledgement can
        // rebase it. Hold the proposal until close either discards it or fails.
        guard !entry.isClosing else { return }
        emit(.externalReloadRequested(proposal))
    }

    public func acknowledgeExternalReload(operationID: UUID, outcome: IOSDocumentReloadOutcome) {
        guard let entry = byIdentity.values.first(where: { $0.pendingProposal?.operationID == operationID }) else {
            return
        }
        guard let proposal = entry.pendingProposal, proposal.operationID == operationID else { return }
        guard guardCurrentAuthority(entry, generation: proposal.accessGeneration) else { return }
        guard let session = entry.session else { return }
        switch outcome {
        case let .installed(revision):
            guard revision.documentID == entry.identity, revision.version == session.version else { return }
            guard !entry.isClosing, !entry.isRetiring, !entry.portClosed else { return }
            guard ExactSourceText.matches(session.text, proposal.text) else { return }
            session.rebaseSavedText(to: proposal.text)
            entry.lastPersistedText = proposal.text
            entry.pendingProposal = nil
            entry.fenced = false
            refreshWritableState(entry)
            emitSnapshot(entry)
        case .deferred:
            break
        case .refused:
            entry.pendingProposal = nil
            entry.fenced = true
            entry.autosaveTask?.cancel()
            setState(.unavailable(accessGeneration: entry.accessGeneration, reason: .sourceChanged), entry: entry)
            if session.isDirty {
                Task { @MainActor in
                    await self.beginConflict(entry, reason: .externalConflict, allowRetry: true)
                }
            }
        }
    }

    public func resolveExternal(
        _ identity: IOSDocumentIdentity,
        choice: IOSExternalResolution
    ) async throws {
        switch choice {
        case .reload:
            try await reloadLatest(identity)
        case let .saveCopy(destination, lease):
            _ = try await copyOriginal(identity, destination: destination, lease: lease)
        }
    }

    public func saveCopy(
        _ identity: IOSDocumentIdentity,
        destination: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSSaveAcknowledgement {
        try await copyOriginal(identity, destination: destination, lease: lease)
    }

    func reloadLatest(_ identity: IOSDocumentIdentity) async throws {
        let entry = try requireEntry(identity)
        guard let session = entry.session else { throw IOSDocumentFailure.unavailable }
        let capturedVersion = session.version
        let generation = entry.accessGeneration
        let read = try await coordinatedAccess.read(
            entry.location,
            lease: entry.lease,
            operationID: UUID(),
            maximumByteCount: maximumExternalBytes
        )
        guard guardCurrentAuthority(entry, generation: generation) else {
            throw IOSDocumentFailure.documentChanged
        }
        guard session.version == capturedVersion else {
            throw IOSDocumentFailure.sourceChanged
        }
        guard let text = IOSDocumentTextCodec.decode(read.data) else {
            throw IOSDocumentFailure.access(.unsupportedType)
        }
        publishReloadProposal(entry, text: text, fileURL: read.location.fileURL)
    }

    func copyOriginal(
        _ identity: IOSDocumentIdentity,
        destination: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSSaveAcknowledgement {
        let entry = try requireEntry(identity)
        guard let session = entry.session else { throw IOSDocumentFailure.unavailable }
        try validate(destination, lease: lease)
        let capturedText = session.text
        let capturedVersion = session.version
        let capturedDirty = session.isDirty
        let operationID = UUID()
        let created: IOSCreatedLeaf
        do {
            created = try await coordinatedAccess.createNewLeaf(
                at: destination,
                data: IOSDocumentTextCodec.encode(capturedText),
                lease: lease,
                operationID: operationID
            )
        } catch {
            throw mapped(error)
        }
        guard ExactSourceText.matches(session.text, capturedText), session.version == capturedVersion else {
            throw IOSDocumentFailure.sourceChanged
        }
        if session.isDirty != capturedDirty {
            throw IOSDocumentFailure.sourceChanged
        }
        let acknowledgement = IOSSaveAcknowledgement(
            operationID: operationID,
            revision: IOSDocumentRevision(documentID: identity, version: capturedVersion),
            savedText: capturedText,
            location: created.location
        )
        emit(.saveCompleted(acknowledgement))
        return acknowledgement
    }
}
