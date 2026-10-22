import UIKit

@MainActor
final class DocumentSession: NSObject {
    let editor: SourceEditor
    let probe: Probe
    private(set) var document: SpikeDocument?
    private(set) var grant: AccessGrant?
    private(set) var ledger: SaveLedger?
    private(set) var opening = false
    private var reloading = false
    private(set) var message = "Open a public test fixture. Owner device gates OPEN."
    var updated: (() -> Void)?
    var delaySave = false
    private var backgroundToken = UIBackgroundTaskIdentifier.invalid
    var dirty: Bool {
        ledger?.dirty ?? false
    }

    var saving: Bool {
        ledger?.active != nil
    }

    var conflict: Bool {
        ledger?.conflict ?? false
    }

    init(editor: SourceEditor, probe: Probe) {
        self.editor = editor
        self.probe = probe
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
            try RecoveryStore.applicationStore().persist(snapshot)
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
        editor.textView.isEditable = false
        defer { opening = false; updated?() }
        if let previous = document {
            let closed = await withCheckedContinuation { continuation in
                previous.close { continuation.resume(returning: $0) }
            }
            guard closed else {
                report("Close failed; original document retained.", event: "close-failed")
                return
            }
            document = nil
            grant = nil
            ledger = nil
        }
        let candidate = SpikeDocument(fileURL: url)
        let success = await withCheckedContinuation { continuation in
            candidate.open { continuation.resume(returning: $0) }
        }
        guard success else {
            report("Open failed/unavailable. No empty document substituted.", event: "open-failed")
            return
        }
        document = candidate
        grant = selectedGrant // Keep scope alive for the entire UIDocument lifetime.
        let identity = UUID()
        ledger = SaveLedger(documentID: identity, source: candidate.loadedSource)
        guard editor.attach(candidate.loadedSource, identity: identity) else {
            ledger?.available = false
            report("Attach refused during composition.", event: "attach-failed")
            return
        }
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
            editor.textView.isEditable = enabled && !conflict && !reloading && ledger?.available == true
            record(enabled ? "document-enable-editing" : "document-disable-editing")
        }
        ledger?.available = !candidate.documentState.contains(.editingDisabled)
        editor.textView.isEditable = ledger?.available == true
        report("Opened in place. Single-file grant does not authorize siblings.", event: "open-succeeded")
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
                completion(false); return
            }
            document.persist(capture.source, baseline: ledger!.savedSource) { [weak self, document] success in
                guard let self, self.document === document else { completion(false); return }
                let durable = success && document.fileURL == capturedURL
                let accepted = ledger?.complete(capture, success: durable) == true
                if !durable {
                    _ = recover(reason: "save-failed-or-location-changed")
                }
                report(durable && accepted ? "Captured revision saved; current dirty state recalculated." :
                    "Save failed. Editor and recovery retained.",
                    event: durable && accepted ? "save-acknowledged" : "save-failed")
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
        if document.documentState.contains(.savingError) || document.documentState.contains(.closed) {
            ledger?.available = false
            _ = recover(reason: "provider-unavailable")
        }
        record("document-state")
    }

    @objc func background() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask(withName: "M0RecoveryAndFlush") { [weak self] in
            guard let self else { return }
            _ = recover(reason: "background-expiration")
            report("Background time expired; save completion remains unconfirmed.", event: "background-expired")
            finishBackground()
        }
        guard recover(reason: "background") else { finishBackground(); return }
        record("background-flush-request")
        save { [weak self] _ in self?.finishBackground() }
    }

    private func finishBackground() {
        if backgroundToken != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundToken)
            backgroundToken = .invalid
        }
    }

    @objc private func foreground() {
        record("foreground")
    }
}
