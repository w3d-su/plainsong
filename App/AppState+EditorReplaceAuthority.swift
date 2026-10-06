import AppKit
import EditorKit
import Foundation
import MarkdownCore

/// What a Replace plan captured about App authority when it was made.
///
/// `generation` is App's monotonic replacement-authority generation; the session and its
/// monotonic `DocumentSession.version` make an edit supersede the plan without adding work
/// to the keystroke path. The editor-side half (key window, installation, applied
/// selection) is `EditorReplaceEditorStamp`, compared by EditorKit at delivery.
struct EditorReplaceAuthorityStamp: Equatable {
    let generation: UInt64
    let session: ObjectIdentifier
    let sourceRevision: Int
}

/// App-owned monotonic replacement-authority generation (`docs/editor-replace-gates.md`
/// §5.7 rule 7). It only ever advances; a plan whose captured generation differs at commit
/// fails before any undo group opens, even if every observable value has since returned.
@MainActor
final class EditorReplaceAuthorityState {
    private(set) var generation: UInt64 = 0
    /// Authorization record of the most recent command, for diagnostics and tests.
    var lastAuthorizationRecord: EditorReplaceAuthorizationRecord?
    /// Test seam: runs inside EditorKit's commit-time authorization call, before App
    /// evaluates it, so a test can make a fence appear between validation and commit.
    var willCheckCommitForTesting: (() -> Void)?
    /// Runs after every advance. `EditorFindHost` uses it to stop a preparing Replace All at
    /// once, so its progress and Cancel never outlive the authority that started it.
    var onAdvance: (() -> Void)?
    private var keyWindowObservation: EditorReplaceKeyWindowObservation?

    func advance() {
        precondition(generation < .max, "Replace authority generation exhausted")
        generation += 1
        onAdvance?()
    }

    /// Key-window changes supersede every outstanding plan. Installed with the first plan:
    /// a plan can only be superseded by changes after its capture.
    func observeKeyWindowChangesIfNeeded() {
        guard keyWindowObservation == nil else { return }
        keyWindowObservation = EditorReplaceKeyWindowObservation { [weak self] in
            self?.advance()
        }
    }
}

/// Owns the key-window notification observers and removes them when released.
private final class EditorReplaceKeyWindowObservation: @unchecked Sendable {
    private let observers: [NSObjectProtocol]

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { onChange() }
                } else {
                    Task { @MainActor in onChange() }
                }
            }
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
extension AppState {
    var editorReplaceAuthorityGeneration: UInt64 {
        editorFindHost.replaceAuthority.generation
    }

    /// Called from `didSet` on the fence and prompt maps `editorReplaceAuthorizationDecision`
    /// reads directly and on editor installations: any of them set **or cleared** advances
    /// the generation. Not hooked: `sessionStateURL`'s inputs (`anchoredSessionFileBindings`,
    /// `unanchoredManagedSessionOwnershipProofs`, `indeterminateSessionWriteContexts`) and
    /// `externalResolutionIntentCaptures`. They are covered by the rekey notification, the
    /// write-fence `didSet`, and the live evaluation at commit.
    func noteEditorReplaceAuthorityInputDidChange() {
        advanceEditorReplaceAuthorityGeneration()
    }

    /// Rebind, reload, rekey, focus, and bar transitions call this directly.
    func advanceEditorReplaceAuthorityGeneration() {
        editorFindHost.replaceAuthority.advance()
    }

    func currentEditorReplaceAuthorityStamp(
        for session: DocumentSession
    ) -> EditorReplaceAuthorityStamp {
        EditorReplaceAuthorityStamp(
            generation: editorReplaceAuthorityGeneration,
            session: ObjectIdentifier(session),
            sourceRevision: session.version
        )
    }

    /// Bar open/close, replacement-row expand/collapse (PR H's collapse seam), and every
    /// find-focus token transition (⌘F request, key-window receipt, ⇧⌘F supersession)
    /// supersede outstanding plans. Counter and query updates do not advance the generation:
    /// the query generation and source revision already fence those. A query or option change
    /// still stops a *preparing* Replace All at once instead of letting it drain to a refusal.
    func noteEditorReplaceFindChromeTransition(
        from old: EditorFindUIState,
        to new: EditorFindUIState
    ) {
        if old.queryText != new.queryText || old.matchCase != new.matchCase || old.wholeWord != new.wholeWord {
            editorFindHost.replaceBatch.supersedeIfPreparing()
        }
        if old.isReplaceRowActive, !new.isReplaceRowActive {
            // Close, collapse, and no-document all end the row's visible state; results and
            // refusals from before do not describe the next time it is shown.
            clearEditorReplaceStatus()
        }
        guard old.isBarVisible != new.isBarVisible
            || old.isReplaceExpanded != new.isReplaceExpanded
            || old.focusRequestID != new.focusRequestID
            || old.focusAppliedID != new.focusAppliedID
            || old.focusSupersededID != new.focusSupersededID
        else {
            return
        }
        advanceEditorReplaceAuthorityGeneration()
    }

    /// Reload or Keep Mine finished converging every live installation (§5.6 last rows).
    ///
    /// No plan made before the resolution can commit: the generation advances. Find is then
    /// revalidated against the accepted source and recomputes **counter-only** when its
    /// binding does not already describe that exact source and revision. Nothing is
    /// queued; the user makes a fresh explicit Replace against the recomputed session.
    func editorReplaceExternalResolutionDidComplete(for session: DocumentSession) {
        advanceEditorReplaceAuthorityGeneration()
        guard session === currentDocument else { return }
        // A "choose Reload or Keep Mine" refusal no longer describes the document.
        clearEditorReplaceStatus()
        refreshEditorFindCounterFromAppSource()
    }

    /// Counter-only Find recompute from App's current source, when Find is bound to this
    /// document but holds a different source or revision. Never navigates and never rebinds.
    @discardableResult
    func refreshEditorFindCounterFromAppSource() -> Bool {
        let controller = editorFindHost.controller
        let revision = UInt64(max(0, currentDocument.version))
        guard controller.query != nil,
              controller.documentBinding.identity == activeEditorDocumentIdentity,
              controller.documentBinding.revision != revision
              || !ExactSourceText.matches(controller.documentBinding.text, currentDocument.text)
        else {
            return false
        }
        ensureEditorFindSessionObserverInstalled()
        controller.documentTextDidChange(text: currentDocument.text, revision: revision)
        return true
    }
}
