import UIKit

@MainActor
final class DocumentSession: NSObject {
    let editor: SourceEditor
    let probe: Probe
    private let closeForReplacement: (SpikeDocument) async -> Bool
    private let closeDiscardedCandidate: (SpikeDocument) async -> Bool
    private let beginBackgroundTask: (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private let persistRecovery: (RecoveryEnvelope) throws -> Void
    private var pendingCandidateClose: (document: SpikeDocument, grant: AccessGrant)?
    private(set) var document: SpikeDocument?
    private(set) var grant: AccessGrant?
    private(set) var ledger: SaveLedger?
    private(set) var opening = false
    private var reloading = false
    private(set) var message = "Open a public test fixture. Owner device gates OPEN."
    var updated: (() -> Void)?
    var delaySave = false
    private var backgroundToken = UIBackgroundTaskIdentifier.invalid
    private var backgroundGeneration: UUID?
    private var backgroundCaptureID: UUID?
    var dirty: Bool {
        ledger?.dirty ?? false
    }

    var saving: Bool {
        ledger?.active != nil
    }

    var conflict: Bool {
        ledger?.conflict ?? false
    }

    init(editor: SourceEditor, probe: Probe,
         closeForReplacement: @escaping (SpikeDocument) async -> Bool = { document in
             await withCheckedContinuation { continuation in
                 document.close { continuation.resume(returning: $0) }
             }
         },
         closeDiscardedCandidate: @escaping (SpikeDocument) async -> Bool = { document in
             await withCheckedContinuation { continuation in
                 document.close { continuation.resume(returning: $0) }
             }
         },
         beginBackgroundTask: @escaping (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
             UIApplication.shared.beginBackgroundTask(withName: "M0RecoveryAndFlush", expirationHandler: $0)
         },
         endBackgroundTask: @escaping (UIBackgroundTaskIdentifier) -> Void = {
             UIApplication.shared.endBackgroundTask($0)
         },
         persistRecovery: @escaping (RecoveryEnvelope) throws -> Void = {
             try RecoveryStore.applicationStore().persist($0)
         })
    {
        self.editor = editor
        self.probe = probe
        self.closeForReplacement = closeForReplacement
        self.closeDiscardedCandidate = closeDiscardedCandidate
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.persistRecovery = persistRecovery
        super.init()
        editor.changed = { [weak self] in self?.sourceChanged() }
        editor.event = { [weak self] event in self?.record(event) }
        NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged),
                                               name: UIDocument.stateChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(background),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func record(_ event: String) {
        probe.record(event, editor: editor, dirty: dirty, saving: saving, conflict: conflict)
        updated?()
    }

    func report(_ message: String, event: String) {
        self.message = message
        record(event)
    }

    func sourceChanged() {
        ledger?.observe(source: editor.textView.text, revision: editor.revision)
        document?.updateChangeCount(.done)
        if dirty {
            _ = recover(reason: editor.textView.markedTextRange == nil ? "edit" : "composition-draft")
        }
        record("source-observed")
    }

    @discardableResult
    func recover(reason: String) -> Bool {
        do {
            let snapshot = RecoveryEnvelope(documentID: editor.documentID, revision: editor.revision,
                                            source: editor.textView.text, reason: reason, time: Date())
            try persistRecovery(snapshot)
            record("recovery-readback-verified")
            return true
        } catch {
            report(
                "Recovery write/readback failed. Preserve editor contents; do not terminate.",
                event: "recovery-failed"
            )
            return false
        }
    }

    func open(url: URL, grant selectedGrant: AccessGrant) async {
        guard !opening, !saving, !reloading, !dirty, editor.textView.markedTextRange == nil else {
            report("Open refused: composition, unsaved edits or file operation active.", event: "open-refused-busy")
            return
        }
        opening = true
        let openingTicket = editor.ticket()
        let previousEditable = editor.textView.isEditable
        var replaced = false
        editor.textView.isEditable = false
        defer {
            opening = false
            editor.textView.isEditable = (replaced || previousEditable) && ledger?.available == true && !conflict &&
                !reloading &&
                document?.documentState.contains(.closed) == false &&
                document?.documentState.contains(.editingDisabled) == false
            updated?()
        }
        // The current document and its grant remain owned until the replacement
        // has loaded. A bad file must not retire a working editor session.
        if let pending = pendingCandidateClose {
            guard await closeDiscardedCandidate(pending.document) else {
                report(
                    "Candidate close is still pending. Original document retained.",
                    event: "candidate-close-pending"
                )
                return
            }
            pendingCandidateClose = nil
        }
        let candidate = SpikeDocument(fileURL: url)
        let success = await withCheckedContinuation { continuation in
            candidate.open { continuation.resume(returning: $0) }
        }
        guard success else {
            report("Open failed/unavailable. Original document retained.", event: "open-failed")
            return
        }
        guard replacementIsCurrent(openingTicket) else {
            await closeCandidate(candidate, grant: selectedGrant)
            report("Open superseded by composition or changed document state.", event: "open-refused-busy")
            return
        }
        let previous = document
        if let previous {
            let closed = await closeForReplacement(previous)
            guard closed else {
                await closeCandidate(candidate, grant: selectedGrant)
                report("Close failed; original document retained.", event: "close-failed")
                return
            }
        }
        let identity = UUID()
        guard replacementIsCurrent(openingTicket), editor.attach(candidate.loadedSource, identity: identity) else {
            // Composition can arrive while UIDocument.close is suspended. Keep
            // the original ownership and reopen it before restoring editability.
            await closeCandidate(candidate, grant: selectedGrant)
            if let previous {
                let reopened = await withCheckedContinuation { continuation in
                    previous.open { continuation.resume(returning: $0) }
                }
                if !reopened {
                    ledger?.available = false
                }
            }
            report(
                "Replacement refused after document state changed. Original source retained.",
                event: "attach-failed"
            )
            return
        }
        replaced = true
        document = candidate
        grant = selectedGrant // Keep scope alive for the entire UIDocument lifetime.
        ledger = SaveLedger(documentID: identity, source: candidate.loadedSource)
        candidate.requestAutosave = { [weak self, weak candidate] completion in
            guard let self, let candidate, document === candidate else { completion(false); return }
            // UIDocument.close invokes autosave while open-switch holds the busy
            // fence. A clean document needs no write and may close successfully.
            if !dirty, !saving {
                completion(true)
            } else {
                save(completion: completion)
            }
        }
        candidate.requestRevert = { [weak self, weak candidate] url, completion in
            guard let self, let candidate, document === candidate else { completion?(false); return }
            externalChange(url: url, completion: completion)
        }
        candidate.editingAvailability = { [weak self, weak candidate] enabled in
            guard let self, let candidate, document === candidate else { return }
            editor.textView.isEditable = enabled && !opening && !conflict && !reloading && ledger?.available == true
            record(enabled ? "document-enable-editing" : "document-disable-editing")
        }
        ledger?.available = !candidate.documentState.contains(.editingDisabled)
        // A successful replacement establishes its own editing availability.
        editor.textView.isEditable = ledger?.available == true
        report("Opened in place. Single-file grant does not authorize siblings.", event: "open-succeeded")
    }

    private func replacementIsCurrent(_ ticket: PresentationTicket) -> Bool {
        editor.documentID == ticket.documentID && editor.revision == ticket.revision &&
            sameSource(editor.textView.text, ticket.source) && editor.textView.markedTextRange == nil &&
            !dirty && !conflict && !reloading
    }

    private func closeCandidate(_ candidate: SpikeDocument, grant: AccessGrant) async {
        candidate.requestAutosave = { $0(true) }
        if await !closeDiscardedCandidate(candidate) {
            pendingCandidateClose = (candidate, grant)
            record("candidate-close-failed-retained")
        }
    }

    func save(completion: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        guard let document, !opening, !reloading, editor.textView.markedTextRange == nil,
              !document.documentState.contains(.inConflict), !document.documentState.contains(.editingDisabled)
        else {
            report("Save refused: no document, composition, conflict or disabled editing.", event: "save-refused-state")
            completion(false); return
        }
        guard !saving, !conflict, ledger?.available == true else { completion(false); return }
        guard dirty else { completion(true); return }
        guard recover(reason: "before-save"), let capture = ledger?.begin() else { completion(false); return }
        record("save-captured")
        let capturedURL = document.fileURL
        let delay = delaySave
        Task { [weak self, document] in
            if delay {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard let self, self.document === document, ledger?.active == capture,
                  !conflict, ledger?.available == true, document.fileURL == capturedURL
            else {
                self?.ledger?.complete(capture, success: false)
                self?.record("save-refused-before-write")
                self?.finishBackground(for: capture)
                completion(false); return
            }
            document.persist(capture.source, baseline: ledger!.savedSource) { [weak self, document] success in
                guard let self else { completion(false); return }
                guard self.document === document else {
                    finishBackground(for: capture)
                    completion(false); return
                }
                let durable = success && document.fileURL == capturedURL
                let accepted = ledger?.complete(capture, success: durable) == true
                if !durable {
                    _ = recover(reason: "save-failed-or-location-changed")
                }
                report(durable && accepted ? "Captured revision saved; current dirty state recalculated." :
                    "Save failed. Editor and recovery retained.",
                    event: durable && accepted ? "save-acknowledged" : "save-failed")
                finishBackground(for: capture)
                completion(durable && accepted)
            }
        }
    }

    func externalChange(url: URL, completion: (@MainActor @Sendable (Bool) -> Void)?) {
        guard let document else { completion?(false); return }
        guard !dirty, !saving, !reloading, editor.textView.markedTextRange == nil else {
            _ = recover(reason: "external-conflict")
            ledger?.conflict = true
            ledger?.available = false
            // Preserve composing text and selection. Block writer independently of UI.
            report(
                "External change while busy/dirty: overwrite blocked; local recovery retained.",
                event: "external-conflict"
            )
            completion?(false); return
        }
        let captured = editor.ticket()
        reloading = true
        editor.textView.isEditable = false
        document.coordinatedRevert(to: url) { [weak self, document] success in
            guard let self, self.document === document else { completion?(false); return }
            reloading = false
            guard success, editor.documentID == captured.documentID, editor.revision == captured.revision,
                  editor.textView.markedTextRange == nil, !dirty
            else {
                ledger?.available = false
                ledger?.conflict = true
                _ = recover(reason: "reload-race-or-failure")
                report(
                    "Reload failed/superseded. Local contents preserved; reselect grant after save-copy.",
                    event: "reload-refused"
                )
                completion?(false); return
            }
            _ = editor.attach(document.loadedSource, identity: captured.documentID)
            ledger = SaveLedger(documentID: captured.documentID, source: document.loadedSource)
            ledger?.observe(source: document.loadedSource, revision: editor.revision)
            editor.textView.isEditable = true
            report("Clean external version loaded in place.", event: "reload-succeeded")
            completion?(true)
        }
    }

    @objc private func documentStateChanged(_ notification: Notification) {
        guard let document, notification.object as? SpikeDocument === document else { return }
        if document.documentState.contains(.inConflict) {
            ledger?.conflict = true
            ledger?.available = false
            _ = recover(reason: "provider-conflict")
        }
        if document.documentState.contains(.savingError) ||
            (document.documentState.contains(.closed) && !opening)
        {
            ledger?.available = false
            _ = recover(reason: "provider-unavailable")
        }
        record("document-state")
    }

    @objc func background() {
        guard backgroundToken == .invalid else { return }
        let generation = UUID()
        backgroundGeneration = generation
        backgroundToken = beginBackgroundTask { [weak self] in
            guard let self, backgroundGeneration == generation else { return }
            _ = recover(reason: "background-expiration")
            report("Background time expired; save completion remains unconfirmed.", event: "background-expired")
            finishBackground()
        }
        let recoveryPersisted = recover(reason: "background")
        record("background-flush-request")
        if let capture = ledger?.active {
            // A writer-busy response is not a completed flush. Its original
            // capture keeps the assertion until completion or expiration.
            backgroundCaptureID = capture.operationID
            return
        }
        guard recoveryPersisted else { finishBackground(); return }
        save { [weak self] _ in
            guard let self, backgroundGeneration == generation else { return }
            finishBackground()
        }
    }

    private func finishBackground(for capture: SaveCapture) {
        guard backgroundCaptureID == capture.operationID else { return }
        finishBackground()
    }

    private func finishBackground() {
        if backgroundToken != .invalid {
            endBackgroundTask(backgroundToken)
            backgroundToken = .invalid
        }
        backgroundCaptureID = nil
        backgroundGeneration = nil
    }

    @objc private func foreground() {
        record("foreground")
    }
}
