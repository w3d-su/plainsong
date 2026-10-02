import Foundation
import MarkdownCore

/// Debounced, revision-fenced in-document find controller (PR B).
///
/// Match work is admitted after debounce and runs off the main actor by default.
/// `Task.detached` does not inherit cancellation and `TextSearchEngine` has no cancel
/// points, so "cancel" means the in-flight result is **dropped** at apply time (fence),
/// not that the engine call is interrupted. Find never mutates source text.
///
/// **Navigation IDs:** when `navigationIDProvider` is installed (production App), IDs come
/// from the shared `editorNavigationGeneration` domain used by workspace search. When nil
/// (unit tests), a controller-local sequence is used — safe only while nothing else shares
/// the `editorNavigationCommand` channel.
@MainActor
public final class EditorFindController {
    public private(set) var session: EditorFindSession?
    public private(set) var pendingNavigationCommand: EditorNavigationCommand?
    public private(set) var documentBinding: EditorFindDocumentBinding
    public private(set) var query: TextSearchQuery?
    public private(set) var caretAnchorUTF16: Int = 0
    public private(set) var queryGeneration: UInt64 = 0
    /// True when the last applied match observed `!Thread.isMainThread` inside the worker.
    public private(set) var lastMatchRanOffMain = false
    public private(set) var completedMatchCount = 0
    public private(set) var cancelledMatchCount = 0
    public private(set) var droppedStaleMatchCount = 0
    /// Ordinary `.edit` schedules. A replacement revision must not increment this.
    private(set) var editScheduleCount = 0
    /// `afterOneReplace` rescans admitted (one full `EditorFindSession.search` each).
    private(set) var replacementEngineInvocationCount = 0
    /// Replacement publications admitted. One revision admits one.
    private(set) var replacementScheduleCount = 0
    private(set) var lastScheduleReason: EditorFindScheduleReason?
    /// Set only while a single Replace's own native write runs (see `+Replacement`).
    var armedReplacementPublication: EditorFindReplacementArm?
    /// Publications recorded by an armed write instead of scheduling `.edit`.
    var recordedReplacementPublicationCount = 0

    /// Debounce before match admission. Tests may set to 0.
    public var debounceNanoseconds: UInt64 = 150_000_000

    /// Optional shared-domain ID source (App installs `advanceEditorNavigationGeneration`).
    /// When nil, falls back to a controller-local sequence for isolated unit tests.
    public var navigationIDProvider: (() -> UInt64)?

    /// Invoked on the main actor after a generation’s session (and optional navigation)
    /// is applied, or after a query is cleared / session invalidated.
    public var onSessionDidChange: (() -> Void)?

    /// Test seam: when true, match work runs on the main actor (off-main negative control).
    /// Internal only — must never be reachable from App or other production clients
    /// (would put the synchronous engine on the main actor and break §12).
    var forceMainActorMatchForTesting = false

    /// Test seam: when set, the match worker awaits `waitIfHeld()` before searching.
    /// Internal only (`@testable import`).
    var testMatchHold: EditorFindMatchHold?

    private var navigationSequence: UInt64 = 0
    private let matchWorker = EditorFindMatchWorker()
    private var stepIntentState = EditorFindStepIntentState()

    public init(documentBinding: EditorFindDocumentBinding = .empty) {
        self.documentBinding = documentBinding
    }

    // MARK: - Document lifecycle (F4 / F4b controller half)

    /// Rebinds to a new document: cancel, clear, re-run. Does **not** auto-navigate.
    public func rebindDocument(_ binding: EditorFindDocumentBinding) {
        armedReplacementPublication = nil
        let identityChanged = binding.identity != documentBinding.identity
        documentBinding = binding
        if identityChanged {
            clearSessionKeepingQuery()
        }
        scheduleMatch(reason: .rebind)
    }

    /// Source publication: an ordinary `.edit` recomputes matches/counter and does
    /// **not** move the selection.
    ///
    /// While a single Replace's own native write is in progress, the publication is
    /// only recorded. The executor then admits it as one `.replacement` rescan that
    /// navigates to the continuation, or hands it back here as an ordinary edit.
    public func documentTextDidChange(text: String, revision: UInt64) {
        guard revision != documentBinding.revision || text != documentBinding.text else {
            return
        }
        if recordArmedReplacementPublication(text: text, revision: revision) {
            return
        }
        documentBinding = EditorFindDocumentBinding(
            identity: documentBinding.identity,
            text: text,
            revision: revision
        )
        scheduleMatch(reason: .edit)
    }

    /// No document remains: cancel and clear session **and** query (F4b controller half).
    /// Leaving `query` set would re-run a background match on the next document bind.
    public func clearForNoDocument() {
        armedReplacementPublication = nil
        cancelInFlightWork()
        documentBinding = .empty
        query = nil
        session = nil
        pendingNavigationCommand = nil
        stepIntentState.clear()
        notifySessionDidChange()
    }

    // MARK: - Query / navigation

    public func setQuery(_ query: TextSearchQuery?, emitsNavigation: Bool = true) {
        self.query = query
        caretAnchorUTF16 = max(0, caretAnchorUTF16)
        // ⌘E / pattern-only updates recompute the counter without auto-jumping.
        scheduleMatch(reason: emitsNavigation ? .query : .patternOnly)
    }

    public func setCaretAnchor(_ utf16: Int) {
        caretAnchorUTF16 = max(0, utf16)
    }

    public func findNext() {
        // While a match is in flight, record intent — do not re-schedule the query
        // (that would restart debounce and drop reverse/forward intent).
        guard var session else {
            stepIntentState.record(1, generation: queryGeneration, hasQuery: query != nil)
            return
        }
        if stepIntentState.consumeCurrentActivation() {
            self.session = session
            emitNavigation(for: session.currentMatch)
            notifySessionDidChange()
            return
        }
        session = session.next()
        self.session = session
        emitNavigation(for: session.currentMatch)
        notifySessionDidChange()
    }

    public func findPrevious() {
        guard var session else {
            stepIntentState.record(-1, generation: queryGeneration, hasQuery: query != nil)
            return
        }
        if stepIntentState.consumeCurrentActivation() {
            self.session = session
            emitNavigation(for: session.currentMatch)
            notifySessionDidChange()
            return
        }
        session = session.previous()
        self.session = session
        emitNavigation(for: session.currentMatch)
        notifySessionDidChange()
    }

    /// Re-activates the current match with a fresh navigation ID (F3).
    public func activateCurrentMatch() {
        stepIntentState.clearCurrentActivation()
        emitNavigation(for: session?.currentMatch)
        notifySessionDidChange()
    }

    /// Retains the resolved ordinal; `cancelInFlightWork` advances the generation so a detached
    /// result drops at apply. With no session yet the query is still debouncing: fencing it would
    /// leave it permanently unusable, so it reruns counter-only. Otherwise ⌘G continues from it.
    public func suspendNavigation() {
        pendingNavigationCommand = nil
        stepIntentState.clear()
        guard session != nil else {
            scheduleMatch(reason: .patternOnly)
            return
        }
        cancelInFlightWork()
        // The retained session already resolved an ordinal, so the next step moves from it.
        stepIntentState.clearCurrentActivation()
        notifySessionDidChange()
    }

    public func cancelInFlightWork() {
        // Count supersession of debounce admission (the common rapid-typing path) or match work.
        if matchWorker.cancel() {
            cancelledMatchCount &+= 1
        }
        // Advance the fence so a detached worker that still finishes cannot apply.
        // scheduleMatch will increment again when it starts a new generation — double
        // advance is fine and keeps cancel-only callers safe.
        queryGeneration &+= 1
    }
}

extension EditorFindController {
    // MARK: - Private

    private func clearSessionKeepingQuery() {
        session = nil
        pendingNavigationCommand = nil
        stepIntentState.clear()
    }

    private func scheduleMatch(reason: EditorFindScheduleReason) {
        if case .replacement = reason {
            assertionFailure("Replacement publications use startReplacementGeneration")
            return
        }
        if reason == .edit {
            editScheduleCount &+= 1
        }
        lastScheduleReason = reason
        let binding = documentBinding
        let query = query
        let anchor = caretAnchorUTF16
        let debounce = debounceNanoseconds
        // Capture ordinal before invalidating session (edit preserves it when still valid).
        let preferredOrdinal: Int? = reason == .edit ? session?.currentOrdinal : nil
        let shouldNavigate = reason.emitsNavigationOnCompletion
        let generation = beginGeneration()

        guard let query, !query.pattern.isEmpty else {
            session = query.map { EditorFindSession.empty(query: $0, caretAnchorUTF16: anchor) }
            pendingNavigationCommand = nil
            stepIntentState.clearPendingSteps()
            notifySessionDidChange()
            return
        }

        let work = Work(
            binding: binding,
            generation: generation,
            query: query,
            caretAnchor: anchor,
            preferredOrdinal: preferredOrdinal,
            shouldNavigate: shouldNavigate
        )
        matchWorker.schedule(owner: self, work: work, debounce: debounce) { controller, work in
            controller.runMatch(work)
        }
    }

    private struct Work {
        let binding: EditorFindDocumentBinding
        let generation: UInt64
        let query: TextSearchQuery
        let caretAnchor: Int
        let preferredOrdinal: Int?
        let shouldNavigate: Bool
    }

    private func runMatch(_ work: Work) {
        startMatchWork(binding: work.binding, generation: work.generation) {
            EditorFindSession.search(
                in: work.binding.text,
                query: work.query,
                caretAnchorUTF16: work.caretAnchor,
                preferredOrdinal: work.preferredOrdinal
            )
        } apply: { controller, session in
            controller.applyMatchResult(
                session,
                generation: work.generation,
                shouldNavigate: work.shouldNavigate
            )
        }
    }

    /// Applies a fence-current search result (`startMatchWork` already checked the fence).
    private func applyMatchResult(
        _ newSession: EditorFindSession,
        generation: UInt64,
        shouldNavigate: Bool
    ) {
        let resolution = stepIntentState.resolve(
            newSession, generation: generation, shouldNavigate: shouldNavigate
        )
        session = resolution.session
        if resolution.emitsNavigation {
            emitNavigation(for: resolution.session.currentMatch)
        }
        notifySessionDidChange()
    }

    private func emitNavigation(for match: TextSearchMatch?) {
        guard let match else { return }
        emitNavigation(to: match.range)
    }

    private func emitNavigation(to selection: NSRange) {
        guard let identity = documentBinding.identity else { return }
        let id: UInt64
        if let navigationIDProvider {
            id = navigationIDProvider()
        } else {
            navigationSequence &+= 1
            id = navigationSequence
        }
        let request = EditorNavigationRequest(
            id: id,
            documentIdentity: identity,
            selection: selection,
            shouldFocusEditor: false
        )
        pendingNavigationCommand = .navigate(request)
    }

    private func notifySessionDidChange() {
        onSessionDidChange?()
    }

    // MARK: - Generations and match work (shared by Find and single Replace)

    /// Fences work and clears results and steps before notifying observers. New presses
    /// record against the returned generation, never superseded query or revision ranges.
    private func beginGeneration() -> UInt64 {
        cancelInFlightWork()
        queryGeneration &+= 1
        session = nil
        pendingNavigationCommand = nil
        stepIntentState.clear()
        notifySessionDidChange()
        return queryGeneration
    }

    /// Delegates weak-owner work to the task owner; current results update counters and apply
    /// here, while superseded results still increment the stale-drop counter.
    private func startMatchWork<Output: Sendable>(
        binding: EditorFindDocumentBinding,
        generation: UInt64,
        compute: @escaping @Sendable () -> Output,
        apply: @escaping @MainActor (EditorFindController, Output) -> Void
    ) {
        matchWorker.start(
            owner: self,
            request: .init(
                binding: binding, generation: generation,
                hold: testMatchHold, forceMain: forceMainActorMatchForTesting
            ),
            compute: compute,
            current: { ($0.documentBinding, $0.queryGeneration) },
            apply: { controller, output, ranOffMain, isCurrent in
                controller.lastMatchRanOffMain = ranOffMain
                guard isCurrent else {
                    controller.droppedStaleMatchCount &+= 1
                    return
                }
                controller.completedMatchCount &+= 1
                apply(controller, output)
            }
        )
    }

    /// Admits one verified single-Replace revision: one `afterOneReplace` rescan, run without
    /// the typing debounce because Replace is one explicit command and the counter is blank
    /// until it lands. A later edit, query, or rebind supersedes it like any generation.
    func startReplacementGeneration(
        plan: EditorReplaceOneMatchPlan,
        text: String,
        revision: UInt64
    ) {
        lastScheduleReason = .replacement(resumeUTF16: plan.resumeUTF16)
        replacementScheduleCount &+= 1
        documentBinding = EditorFindDocumentBinding(
            identity: documentBinding.identity,
            text: text,
            revision: revision
        )
        let generation = beginGeneration()
        replacementEngineInvocationCount &+= 1
        // Identity is re-read after beginGeneration's callback, exactly as the pre-split fence.
        let binding = EditorFindDocumentBinding(identity: documentBinding.identity, text: text, revision: revision)
        startMatchWork(binding: binding, generation: generation) {
            EditorReplaceContinuationPlanning.afterOneReplace(plan: plan, postWriteSource: text)
        } apply: { controller, continuation in
            controller.installContinuation(continuation, stepsRecordedFor: generation)
        }
    }

    /// Installs a Replace continuation and emits its non-focus-stealing navigation: the new
    /// current match, or the collapsed selection at `resumeUTF16` when none follows.
    ///
    /// ⌘G / ⇧⌘G pressed while `generation` was computing apply on top of the continuation,
    /// each as one step past it (a navigating result, like `.query`). Pass `nil` when no
    /// generation was in flight (literal-identical advance).
    func installContinuation(
        _ continuation: EditorReplaceContinuation,
        stepsRecordedFor generation: UInt64?
    ) {
        let resolved = stepIntentState.resolveContinuation(continuation.session, generation: generation)
        session = resolved
        caretAnchorUTF16 = continuation.resumeUTF16
        emitNavigation(to: resolved.currentMatch?.range ?? continuation.collapsedSelection)
        notifySessionDidChange()
    }
}
