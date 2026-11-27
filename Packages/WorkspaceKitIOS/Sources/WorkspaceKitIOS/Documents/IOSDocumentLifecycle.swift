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
            // A retained conflict can still own an explicit Reload. Resume that
            // request after closing, but never revive an automatic proposal over
            // a later provider fence. Live admission also rejects changed source.
            if let proposal = entry.pendingProposal,
               !entry.fenced || entry.explicitReloadOperationID == proposal.operationID,
               reloadAdmission(for: proposal) == .installable
            {
                emit(.externalReloadRequested(proposal))
            }
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
        // Verification of an untouched failed open is only a write-permission
        // probe: closing discards no user work, so it must not wait for that probe.
        if !entry.isUntouchedOpeningSnapshot {
            await drainExternalReadsForClose(entry)
        }
        if entry.needsCloseRecovery || externalBarrierBlocksClose(entry)
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
        if session.version != version || entry.needsCloseRecovery || externalBarrierBlocksClose(entry)
            || !guardCurrentAuthority(entry, generation: generation)
        {
            let retained = await retainDraft(entry)
            await reopenRetainedDraft(entry, generation: generation)
            return retained
        }
        entry.externalToken = nil
        entry.pendingProposal = nil
        entry.explicitReloadOperationID = nil
        entry.hasDeferredExternalChange = false
        publishClosed(entry, superseded: false)
        return .closed
    }

    func externalBarrierBlocksClose(_ entry: IOSDocumentEntry) -> Bool {
        !entry.isUntouchedOpeningSnapshot && (entry.hasDeferredExternalChange || entry.externalToken != nil)
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

    /// A scene may leave an unavailable file after its latest edits are durable
    /// and the provider has actually relinquished its writer. An identity the store
    /// does not hold returns without an error: closed history is bounded, so an
    /// evicted identity cannot be told apart from one this store never issued.
    public func retireRetainedWriter(_ identity: IOSDocumentIdentity, disconnecting: Bool) async throws {
        // Evicted terminal IDs have already relinquished their writer.
        guard let registered = byIdentity[identity], !registered.closed else { return }
        let entry = try requireEntry(identity)
        guard disconnecting || entry.fenced || !entry.allowsProviderWrite || !leaseStillAuthorizes(
            entry,
            generation: entry.accessGeneration
        ),
            disconnecting || entry.explicitReloadOperationID == nil
        else { throw IOSDocumentFailure.closeFailed }
        try await retireForReplacement(entry)
    }

    /// A replacement keeps the old registry slot until every old operation is drained.
    func retireForReplacement(_ entry: IOSDocumentEntry) async throws {
        if let retirement = entry.retirementTask {
            _ = try await retirement.value
            return
        }
        entry.cloudResolution?.cancel()
        entry.isRetiring = true
        entry.isClosing = true
        entry.autosaveTask?.cancel()
        entry.externalToken = nil
        entry.pendingProposal = nil
        entry.explicitReloadOperationID = nil
        refreshWritableState(entry)
        let task = Task { @MainActor in try await self.performRetirement(entry) }
        entry.retirementTask = task
        defer {
            entry.retirementTask = nil
            entry.isRetiring = false
            entry.isClosing = false
            refreshWritableState(entry)
        }
        _ = try await task.value
    }

    func performRetirement(_ entry: IOSDocumentEntry) async throws -> IOSDocumentCloseOutcome {
        do {
            if !entry.openFinished {
                _ = try await entry.awaitReady()
            }
            // Preserve a dirty snapshot even while an earlier provider write is parked.
            var retainedRecovery = try await persistRetirementRecovery(entry)
            await entry.queue.drain()
            let reads = Array(entry.externalReadTasks.values)
            reads.forEach { $0.cancel() }
            for read in reads {
                await read.value
            }
            retainedRecovery = try await persistRetirementRecovery(entry) ?? retainedRecovery
            if !entry.portClosed {
                try await entry.filePort.close()
                entry.portClosed = true
            }
            // Edits received during either drain or close must also be durable.
            retainedRecovery = try await persistRetirementRecovery(entry) ?? retainedRecovery
            if let session = entry.session, entry.needsCloseRecovery {
                guard retainedRecovery?.revision.version == session.version else {
                    throw IOSDocumentFailure.sourceChanged
                }
            }
            publishClosed(entry, superseded: true)
            if let retainedRecovery {
                return .retained(recovery: retainedRecovery)
            }
            return .closed
        } catch {
            entry.fenced = true
            let failure = (mapped(error) as? IOSDocumentFailure) ?? .closeFailed
            setState(.unavailable(accessGeneration: entry.accessGeneration, reason: failure), entry: entry)
            emit(.failed(entry.identity, operationID: UUID(), reason: failure))
            throw failure
        }
    }

    /// Historical recovery does not make a subsequently saved clean document a retained draft.
    func persistRetirementRecovery(_ entry: IOSDocumentEntry) async throws -> IOSRecoveryReceipt? {
        guard entry.needsCloseRecovery else { return nil }
        return try await persistStableRecovery(entry, reason: .closeIncomplete)
    }

    func persistStableRecovery(_ entry: IOSDocumentEntry,
                               reason: IOSRecoveryReason) async throws -> IOSRecoveryReceipt?
    {
        guard let session = entry.session else { return nil }
        for _ in 0 ..< 3 {
            guard entry.needsCloseRecovery else { return entry.recoveryReceipt }
            let version = session.version
            let text = session.text
            let receipt = try await persistRecovery(entry, reason: reason)
            guard session.version == version, ExactSourceText.matches(session.text, text) else { continue }
            return receipt
        }
        throw IOSDocumentFailure.sourceChanged
    }

    func publishClosed(_ entry: IOSDocumentEntry, superseded: Bool) {
        entry.checkpoint = nil
        entry.retainedDraft = nil
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
        entry.filePort.setHandler(nil)
        forgetClosedEntry(entry)
        entry.lease.release()
        entry.coalescedLeases.forEach { $0.release() }
        entry.coalescedLeases = []
        emit(.closed(entry.identity))
    }
}
