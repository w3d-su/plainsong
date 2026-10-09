import Foundation
import MarkdownCore
import WorkspaceCore

extension IOSUIDocumentStore {
    func handleFileEvent(_ event: IOSDocumentFileEvent, entry: IOSDocumentEntry) {
        guard !entry.superseded, !entry.closed else { return }
        switch event {
        case .externalChange:
            startExternalRead(entry)
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

    func startExternalRead(_ entry: IOSDocumentEntry) {
        guard entry.session != nil, guardCurrentAuthority(entry, generation: entry.accessGeneration) else { return }
        let token = UUID()
        entry.externalToken = token
        let capturedVersion = entry.session?.version ?? 0
        let generation = entry.accessGeneration
        let identity = entry.identity
        let location = entry.location
        let lease = entry.lease
        let operationID = UUID()
        Task { @MainActor in
            do {
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
                self.failExternalRead(entry: entry, token: token, error: error)
            }
        }
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
            emit(.failed(entry.identity, operationID: read.operationID, reason: .access(.unsupportedType)))
            return
        }
        if matchesSelfWrite(entry, externalText) {
            return
        }
        guard let session = entry.session else { return }
        if ExactSourceText.matches(externalText, session.text), !session.isDirty {
            return
        }
        if session.version != capturedVersion || session.isDirty || entry.fenced {
            if session.isDirty || entry.fenced {
                await beginConflict(entry, reason: .externalConflict, allowRetry: true)
            }
            return
        }
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

    func failExternalRead(entry: IOSDocumentEntry, token: UUID, error: Error) {
        guard entry.externalToken == token, guardCurrentAuthority(entry, generation: entry.accessGeneration) else {
            return
        }
        if error is CancellationError {
            return
        }
        let failure = mapped(error)
        if let documentFailure = failure as? IOSDocumentFailure {
            emit(.failed(entry.identity, operationID: UUID(), reason: documentFailure))
        }
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
            guard revision.documentID == entry.identity else { return }
            guard ExactSourceText.matches(session.text, proposal.text) else { return }
            session.rebaseSavedText(to: proposal.text)
            entry.lastPersistedText = proposal.text
            entry.pendingProposal = nil
            entry.fenced = false
            entry.allowsProviderWrite = !entry.lease.isReleased
            setState(
                .ready(canWrite: entry.allowsProviderWrite, accessGeneration: entry.accessGeneration),
                entry: entry
            )
            emitSnapshot(entry)
        case .deferred:
            break
        case .refused:
            entry.pendingProposal = nil
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
