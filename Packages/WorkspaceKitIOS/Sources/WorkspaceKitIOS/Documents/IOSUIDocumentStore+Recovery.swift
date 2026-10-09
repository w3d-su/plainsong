import Foundation
import MarkdownCore

extension IOSUIDocumentStore {
    func beginConflict(_ entry: IOSDocumentEntry, reason: IOSRecoveryReason, allowRetry: Bool) async {
        guard guardCurrentAuthority(entry, generation: entry.accessGeneration), let session = entry.session else {
            return
        }
        entry.fenced = true
        entry.allowsProviderWrite = false
        entry.autosaveTask?.cancel()
        let captured = session.text
        guard let record = recoveryRecord(entry, reason: reason) else { return }
        do {
            let receipt = try await recovery.persist(record)
            guard guardCurrentAuthority(entry, generation: entry.accessGeneration) else { return }
            guard ExactSourceText.matches(session.text, captured) else {
                if allowRetry {
                    await beginConflict(entry, reason: reason, allowRetry: false)
                } else {
                    publishRecoveryFailure(entry, operationID: record.operationID)
                }
                return
            }
            publishConflictAfterRecovery(entry, receipt)
        } catch {
            guard guardCurrentAuthority(entry, generation: entry.accessGeneration) else { return }
            publishRecoveryFailure(entry, operationID: record.operationID)
        }
    }

    /// Conflict becomes visible only after the recovery record is durable.
    func publishConflictAfterRecovery(_ entry: IOSDocumentEntry, _ receipt: IOSRecoveryReceipt) {
        entry.fenced = true
        entry.allowsProviderWrite = false
        entry.recoveryReceipt = receipt
        setState(.conflict(accessGeneration: entry.accessGeneration, recovery: receipt), entry: entry)
        emit(.recoveryPersisted(receipt))
    }

    func publishRecoveryFailure(_ entry: IOSDocumentEntry, operationID: UUID) {
        entry.fenced = true
        entry.allowsProviderWrite = false
        setState(
            .unavailable(accessGeneration: entry.accessGeneration, reason: .recoveryFailed),
            entry: entry
        )
        emit(.failed(entry.identity, operationID: operationID, reason: .recoveryFailed))
    }

    func recoveryRecord(_ entry: IOSDocumentEntry, reason: IOSRecoveryReason) -> IOSRecoveryRecord? {
        guard let session = entry.session else { return nil }
        return IOSRecoveryRecord(
            recordID: UUID(),
            operationID: UUID(),
            documentID: entry.identity.rawValue,
            revisionVersion: session.version,
            workspaceID: entry.location.workspaceID.rawValue,
            accessGeneration: entry.accessGeneration,
            resourceID: entry.location.resourceID?.rawValue,
            relativePathUTF8: Data(entry.location.relativePath.utf8),
            fileURLPath: entry.location.fileURL.path(percentEncoded: false),
            source: session.text,
            baseline: entry.lastPersistedText ?? "",
            reason: reason
        )
    }

    func persistRecovery(_ entry: IOSDocumentEntry, reason: IOSRecoveryReason) async throws -> IOSRecoveryReceipt {
        guard let record = recoveryRecord(entry, reason: reason) else {
            throw IOSDocumentFailure.recoveryFailed
        }
        let receipt = try await recovery.persist(record)
        entry.recoveryReceipt = receipt
        return receipt
    }

    public func close(_ identity: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome {
        let entry = try requireEntry(identity)
        entry.autosaveTask?.cancel()
        if let session = entry.session, session.isDirty, !entry.fenced, entry.allowsProviderWrite {
            do {
                _ = try await save(identity)
            } catch {
                // The draft stays. Close does not become success.
            }
        }
        await entry.queue.drain()
        if let session = entry.session, session.isDirty || entry.fenced {
            let receipt = try? await persistRecovery(entry, reason: .closeIncomplete)
            return .retained(recovery: receipt ?? entry.recoveryReceipt)
        }
        do {
            try await entry.filePort.close()
        } catch {
            emit(.failed(identity, operationID: UUID(), reason: .closeFailed))
            throw IOSDocumentFailure.closeFailed
        }
        entry.closed = true
        entry.textTask?.cancel()
        entry.allowsProviderWrite = false
        setState(.closed(accessGeneration: entry.accessGeneration), entry: entry)
        if byResource[entry.resourceKey] === entry {
            byResource[entry.resourceKey] = nil
        }
        entry.lease.release()
        emit(.closed(identity))
        return .closed
    }

    public func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        let identities = byIdentity.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        var outcomes: [IOSDocumentFlushOutcome] = []
        for identity in identities {
            guard let entry = byIdentity[identity], !entry.closed, !entry.superseded else { continue }
            if let outcome = await flush(entry) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    func flush(_ entry: IOSDocumentEntry) async -> IOSDocumentFlushOutcome? {
        guard let session = entry.session else { return nil }
        let needsWork = session.isDirty || entry.inFlightText != nil
        if !needsWork {
            return nil
        }
        let receipt: IOSRecoveryReceipt? = if session.isDirty {
            try? await persistRecovery(entry, reason: .backgroundDeadline)
        } else {
            entry.recoveryReceipt
        }
        let gate = FlushGate()
        let saveTask = Task { @MainActor in
            let outcome = await self.finishFlushSave(entry, receipt: receipt)
            await gate.finish(outcome)
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.timing.backgroundFlushNanoseconds)
            await gate.timeout(identity: entry.identity, receipt: receipt)
        }
        let outcome = await gate.result()
        timeout.cancel()
        _ = saveTask
        return outcome
    }

    func finishFlushSave(
        _ entry: IOSDocumentEntry,
        receipt: IOSRecoveryReceipt?
    ) async -> IOSDocumentFlushOutcome {
        if entry.fenced || !entry.allowsProviderWrite {
            if let receipt {
                return .recovered(receipt)
            }
            return .retained(entry.identity, .conflict)
        }
        do {
            let acknowledgement = try await save(entry.identity)
            return .saved(acknowledgement)
        } catch {
            if let receipt {
                return .recovered(receipt)
            }
            return .retained(entry.identity, (mapped(error) as? IOSDocumentFailure) ?? .indeterminate)
        }
    }
}

private actor FlushGate {
    private var continuation: CheckedContinuation<IOSDocumentFlushOutcome, Never>?
    private var value: IOSDocumentFlushOutcome?

    func finish(_ outcome: IOSDocumentFlushOutcome) {
        resolve(outcome)
    }

    func timeout(identity: IOSDocumentIdentity, receipt: IOSRecoveryReceipt?) {
        if let receipt {
            resolve(.recovered(receipt))
        } else {
            resolve(.retained(identity, .recoveryFailed))
        }
    }

    func result() async -> IOSDocumentFlushOutcome {
        if let value {
            return value
        }
        return await withCheckedContinuation { continuation in
            if let value {
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
            }
        }
    }

    private func resolve(_ outcome: IOSDocumentFlushOutcome) {
        guard value == nil else { return }
        value = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
