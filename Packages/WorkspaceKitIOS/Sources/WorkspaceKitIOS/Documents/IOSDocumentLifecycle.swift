import Foundation
import MarkdownCore

extension IOSUIDocumentStore {
    func performClose(_ entry: IOSDocumentEntry) async throws -> IOSDocumentCloseOutcome {
        defer {
            entry.isClosing = false
            if entry.hasDeferredExternalChange {
                // Install an observation token before autosave admission is reconsidered.
                startExternalRead(entry)
            }
            refreshWritableState(entry)
            resumeAutosaveAfterClose(entry)
        }
        let generation = entry.accessGeneration
        if entry.session?.isDirty == true, !writeBarrier(entry, allowsClosing: true), entry.allowsProviderWrite {
            _ = try? await saveSnapshot(entry, allowsClosing: true)
        }
        await entry.queue.drain()
        // A provider's own save notification can already be reading the durable
        // baseline. Let those issued observations finish before deciding whether
        // close must retain the writer; cancellation is not proof of clean bytes.
        await drainExternalReadsForClose(entry)
        if entry.session?.isDirty == true || entry.fenced || entry.hasDeferredExternalChange
            || entry.externalToken != nil || entry.pendingProposal != nil
            || !guardCurrentAuthority(entry, generation: generation)
        {
            return await retainDraft(entry)
        }
        guard let session = entry.session else { throw IOSDocumentFailure.unavailable }
        let version = session.version
        do {
            try await entry.filePort.close()
            entry.portClosed = true
        } catch {
            emit(.failed(entry.identity, operationID: UUID(), reason: .closeFailed))
            throw IOSDocumentFailure.closeFailed
        }
        // Closing a provider is asynchronous. A newer source cannot be retired by its result.
        if session.version != version || session.isDirty || entry.fenced || entry.hasDeferredExternalChange
            || entry.externalToken != nil || entry.pendingProposal != nil
            || !guardCurrentAuthority(entry, generation: generation)
        {
            let retained = await retainDraft(entry)
            await reopenRetainedDraft(entry, generation: generation)
            return retained
        }
        publishClosed(entry, superseded: false)
        return .closed
    }

    func drainExternalReadsForClose(_ entry: IOSDocumentEntry) async {
        while true {
            let reads = Array(entry.externalReadTasks.values)
            if !reads.isEmpty {
                for read in reads {
                    await read.value
                }
                continue
            }
            // A deferred self-notice can be verified after the writer drains. Do not
            // replace an unresolved read, proposal or conflict merely to finish close.
            guard entry.hasDeferredExternalChange, entry.externalToken == nil,
                  entry.pendingProposal == nil, !entry.fenced
            else { return }
            startExternalRead(entry, allowsClosingObservation: true)
            // Revocation or a closed provider keeps the deferred barrier intact.
            guard !entry.externalReadTasks.isEmpty else { return }
        }
    }

    func retainDraft(_ entry: IOSDocumentEntry) async -> IOSDocumentCloseOutcome {
        do {
            let receipt = try await persistStableRecovery(entry, reason: .closeIncomplete)
            return .retained(recovery: receipt ?? entry.recoveryReceipt)
        } catch {
            publishRecoveryFailure(entry, operationID: UUID())
            return .retained(recovery: entry.recoveryReceipt)
        }
    }

    func reopenRetainedDraft(_ entry: IOSDocumentEntry, generation: UInt64) async {
        guard entry.portClosed, guardCurrentAuthority(entry, generation: generation) else { return }
        do {
            let opened = try await entry.filePort.open()
            entry.portClosed = false
            guard guardCurrentAuthority(entry, generation: generation) else {
                fenceUnavailable(entry, .documentChanged)
                return
            }
            guard let diskText = IOSDocumentTextCodec.decode(opened.data) else {
                throw IOSDocumentFailure.access(.unsupportedType)
            }
            entry.allowsProviderWrite = opened.canWrite
            guard let baseline = entry.lastPersistedText, ExactSourceText.matches(baseline, diskText) else {
                await beginConflict(entry, reason: .externalConflict, allowRetry: true)
                return
            }
        } catch {
            fenceUnavailable(entry, (mapped(error) as? IOSDocumentFailure) ?? .unavailable)
        }
    }

    /// A replacement keeps the old registry slot until every old operation is drained.
    func retireForReplacement(_ entry: IOSDocumentEntry) async throws {
        if let retirement = entry.retirementTask {
            try await retirement.value
            return
        }
        entry.isRetiring = true
        entry.isClosing = true
        entry.autosaveTask?.cancel()
        entry.externalToken = nil
        entry.pendingProposal = nil
        refreshWritableState(entry)
        let task = Task { @MainActor in try await self.performRetirement(entry) }
        entry.retirementTask = task
        defer {
            entry.retirementTask = nil
            entry.isRetiring = false
            entry.isClosing = false
            refreshWritableState(entry)
        }
        try await task.value
    }

    func performRetirement(_ entry: IOSDocumentEntry) async throws {
        do {
            if !entry.openFinished {
                _ = try await entry.awaitReady()
            }
            // Preserve a dirty snapshot even while an earlier provider write is parked.
            _ = try await persistStableRecovery(entry, reason: .closeIncomplete)
            await entry.queue.drain()
            let reads = Array(entry.externalReadTasks.values)
            reads.forEach { $0.cancel() }
            for read in reads {
                await read.value
            }
            _ = try await persistStableRecovery(entry, reason: .closeIncomplete)
            if !entry.portClosed {
                try await entry.filePort.close()
                entry.portClosed = true
            }
            // Edits received during either drain or close must also be durable.
            _ = try await persistStableRecovery(entry, reason: .closeIncomplete)
            publishClosed(entry, superseded: true)
        } catch {
            entry.fenced = true
            let failure = (mapped(error) as? IOSDocumentFailure) ?? .closeFailed
            setState(.unavailable(accessGeneration: entry.accessGeneration, reason: failure), entry: entry)
            emit(.failed(entry.identity, operationID: UUID(), reason: failure))
            throw failure
        }
    }

    func persistStableRecovery(_ entry: IOSDocumentEntry,
                               reason: IOSRecoveryReason) async throws -> IOSRecoveryReceipt?
    {
        guard let session = entry.session else { return nil }
        for _ in 0 ..< 3 {
            guard session.isDirty || entry.fenced else { return entry.recoveryReceipt }
            let version = session.version
            let text = session.text
            let receipt = try await persistRecovery(entry, reason: reason)
            guard session.version == version, ExactSourceText.matches(session.text, text) else { continue }
            return receipt
        }
        throw IOSDocumentFailure.sourceChanged
    }

    func publishClosed(_ entry: IOSDocumentEntry, superseded: Bool) {
        entry.closed = true
        entry.superseded = superseded
        entry.fenced = true
        entry.allowsProviderWrite = false
        entry.textTask?.cancel()
        entry.autosaveTask?.cancel()
        setState(.closed(accessGeneration: entry.accessGeneration), entry: entry)
        if byResource[entry.resourceKey] === entry {
            byResource[entry.resourceKey] = nil
        }
        entry.lease.release()
        emit(.closed(entry.identity))
    }
}
