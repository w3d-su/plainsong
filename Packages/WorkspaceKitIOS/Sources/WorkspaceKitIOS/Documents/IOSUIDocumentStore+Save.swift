import Foundation
import MarkdownCore

extension IOSUIDocumentStore {
    public func save(_ identity: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        try Task.checkCancellation()
        let entry = try requireEntry(identity)
        guard entry.session != nil else { throw IOSDocumentFailure.unavailable }
        guard !writeBarrier(entry) else { throw IOSDocumentFailure.conflict }
        return try await saveSnapshot(entry, allowsClosing: false)
    }

    func saveSnapshot(_ entry: IOSDocumentEntry, allowsClosing: Bool) async throws -> IOSSaveAcknowledgement {
        guard let session = entry.session else { throw IOSDocumentFailure.unavailable }
        let identity = entry.identity
        let operation = IOSDocumentSaveOperation(
            sequence: entry.nextSequence + 1,
            operationID: UUID(),
            snapshotText: session.text,
            capturedVersion: session.version,
            accessGeneration: entry.accessGeneration,
            identity: identity,
            allowsClosing: allowsClosing
        )
        entry.nextSequence = operation.sequence
        return try await enqueue(entry, operation)
    }

    func watchEdits(_ entry: IOSDocumentEntry) {
        guard let session = entry.session else { return }
        entry.textTask = Task { @MainActor in
            for await _ in session.textChanges(includeCurrent: false) {
                self.scheduleAutosave(entry)
            }
        }
    }

    func scheduleAutosave(_ entry: IOSDocumentEntry) {
        entry.autosaveGeneration += 1
        let generation = entry.autosaveGeneration
        entry.autosaveTask?.cancel()
        entry.autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.timing.autosaveDelayNanoseconds)
            guard !Task.isCancelled, entry.autosaveGeneration == generation else { return }
            guard let session = entry.session, session.isDirty else { return }
            guard !self.writeBarrier(entry), entry.allowsProviderWrite else { return }
            guard self.guardCurrentAuthority(entry, generation: entry.accessGeneration) else { return }
            _ = try? await self.save(entry.identity)
        }
    }

    func enqueue(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation
    ) async throws -> IOSSaveAcknowledgement {
        try await withCheckedThrowingContinuation { continuation in
            entry.queue.enqueue {
                do {
                    let acknowledgement = try await self.performSave(entry, operation)
                    continuation.resume(returning: acknowledgement)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func performSave(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation
    ) async throws -> IOSSaveAcknowledgement {
        guard guardSaveAuthority(entry, operation) else {
            throw IOSDocumentFailure.documentChanged
        }
        if writeBarrier(entry, allowsClosing: operation.allowsClosing) {
            throw IOSDocumentFailure.conflict
        }
        if !entry.allowsProviderWrite {
            throw IOSDocumentFailure.access(.readOnly)
        }
        if baselineAlreadyHolds(entry, operation) {
            return acknowledgeWithoutWrite(entry, operation)
        }
        entry.inFlightText = operation.snapshotText
        setState(
            .saving(
                canWrite: !writeBarrier(entry) && entry.allowsProviderWrite && !entry.lease.isReleased,
                accessGeneration: entry.accessGeneration,
                operationID: operation.operationID
            ),
            entry: entry
        )
        let disposition: IOSDocumentFileWriteDisposition = await withCheckedContinuation { continuation in
            var resumed = false
            entry.filePort.save(
                snapshot: IOSDocumentTextCodec.encode(operation.snapshotText),
                operationID: operation.operationID
            ) { disposition in
                self.applySaveResult(entry, operation, disposition)
                if !resumed {
                    resumed = true
                    continuation.resume(returning: disposition)
                }
            }
        }
        switch disposition {
        case .stored:
            guard let acknowledgement = entry.lastAcknowledgement,
                  acknowledgement.operationID == operation.operationID
            else {
                throw IOSDocumentFailure.documentChanged
            }
            return acknowledgement
        case .failed:
            throw IOSDocumentFailure.saveFailed
        case .indeterminate:
            throw IOSDocumentFailure.indeterminate
        }
    }

    func baselineAlreadyHolds(_ entry: IOSDocumentEntry, _ operation: IOSDocumentSaveOperation) -> Bool {
        guard let baseline = entry.lastPersistedText, let session = entry.session else { return false }
        return !session.isDirty
            && ExactSourceText.matches(baseline, operation.snapshotText)
            && ExactSourceText.matches(session.text, operation.snapshotText)
    }

    func acknowledgeWithoutWrite(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation
    ) -> IOSSaveAcknowledgement {
        entry.lastAcknowledgedSequence = max(entry.lastAcknowledgedSequence, operation.sequence)
        let acknowledgement = acknowledgement(entry, operation)
        entry.lastAcknowledgement = acknowledgement
        emit(.saveCompleted(acknowledgement))
        return acknowledgement
    }

    /// A callback for an older or already finished operation cannot move the baseline.
    func applySaveResult(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation,
        _ disposition: IOSDocumentFileWriteDisposition
    ) {
        guard let acknowledged = entryForAcknowledgement(entry, operation) else {
            entry.inFlightText = nil
            return
        }
        guard operation.sequence > acknowledged.lastAcknowledgedSequence else { return }
        switch disposition {
        case .stored:
            acknowledgePersistedSnapshot(acknowledged, operation)
        case .failed:
            acknowledged.lastAcknowledgedSequence = operation.sequence
            rejectSave(acknowledged, operation, .saveFailed)
        case .indeterminate:
            acknowledged.lastAcknowledgedSequence = operation.sequence
            rejectSave(acknowledged, operation, .indeterminate)
        }
    }

    /// Returns the entry a provider completion is allowed to update.
    /// A replaced root or released lease yields nil so the new session stays untouched.
    func entryForAcknowledgement(
        _ captured: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation
    ) -> IOSDocumentEntry? {
        guard guardSaveAuthority(captured, operation) else { return nil }
        guard byResource[captured.resourceKey] === captured else { return nil }
        return captured
    }

    func guardSaveAuthority(_ entry: IOSDocumentEntry, _ operation: IOSDocumentSaveOperation) -> Bool {
        guard entry.identity == operation.identity else { return false }
        return guardCurrentAuthority(entry, generation: operation.accessGeneration)
    }

    /// Baseline only. `markSaved(text:url:)` would replace live source with this snapshot.
    func acknowledgePersistedSnapshot(_ entry: IOSDocumentEntry, _ operation: IOSDocumentSaveOperation) {
        guard let session = entry.session else { return }
        session.rebaseSavedText(to: operation.snapshotText)
        entry.lastPersistedText = operation.snapshotText
        entry.lastAcknowledgedSequence = operation.sequence
        entry.inFlightText = nil
        let acknowledgement = acknowledgement(entry, operation)
        entry.lastAcknowledgement = acknowledgement
        refreshWritableState(entry)
        emit(.saveCompleted(acknowledgement))
        emitSnapshot(entry)
    }

    func rejectSave(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation,
        _ failure: IOSDocumentFailure
    ) {
        entry.inFlightText = nil
        if guardSaveAuthority(entry, operation), !entry.fenced {
            refreshWritableState(entry)
        }
        emit(.failed(entry.identity, operationID: operation.operationID, reason: failure))
    }

    func acknowledgement(
        _ entry: IOSDocumentEntry,
        _ operation: IOSDocumentSaveOperation
    ) -> IOSSaveAcknowledgement {
        IOSSaveAcknowledgement(
            operationID: operation.operationID,
            revision: IOSDocumentRevision(documentID: operation.identity, version: operation.capturedVersion),
            savedText: operation.snapshotText,
            location: entry.location
        )
    }
}
