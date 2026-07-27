import Foundation
import MarkdownCore

/// Immutable document binding observed by in-document find.
public struct EditorFindDocumentBinding: Equatable, Sendable {
    public let identity: EditorDocumentIdentity?
    public let text: String
    public let revision: UInt64

    public init(identity: EditorDocumentIdentity?, text: String, revision: UInt64) {
        self.identity = identity
        self.text = text
        self.revision = revision
    }

    public static let empty = EditorFindDocumentBinding(identity: nil, text: "", revision: 0)
}

/// Test seam: holds off-main match work until `release()` so stale-completion races
/// can be made deterministic. Internal only (`@testable import`); not shipping API.
final class EditorFindMatchHold: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func waitIfHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isHeld {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        isHeld = false
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Fence token for an in-flight match computation.
private struct EditorFindMatchFence: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let sourceRevision: UInt64
    let queryGeneration: UInt64
}

/// Why a match was scheduled — decides whether completion emits navigation.
///
/// Product rules (docs/editor-find-gates.md §5.1):
/// - `.query` → navigate to the match resolved from the caret anchor
/// - `.edit` / `.rebind` → recompute session/counter only; do **not** move selection
enum EditorFindScheduleReason: Equatable {
    case query
    case edit
    case rebind

    var emitsNavigationOnCompletion: Bool {
        switch self {
        case .query: true
        case .edit, .rebind: false
        }
    }
}

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
    private var matchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// After non-navigating recompute (edit/rebind), first next/previous activates the
    /// current ordinal instead of stepping past it.
    private var shouldActivateCurrentOnNextStep = false

    public init(documentBinding: EditorFindDocumentBinding = .empty) {
        self.documentBinding = documentBinding
    }

    deinit {
        matchTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Document lifecycle (F4 / F4b controller half)

    /// Rebinds to a new document: cancel, clear, re-run. Does **not** auto-navigate.
    public func rebindDocument(_ binding: EditorFindDocumentBinding) {
        let identityChanged = binding.identity != documentBinding.identity
        documentBinding = binding
        if identityChanged {
            clearSessionKeepingQuery()
        }
        scheduleMatch(reason: .rebind)
    }

    /// Edit invalidation: recompute matches/counter; does **not** move selection.
    public func documentTextDidChange(text: String, revision: UInt64) {
        guard revision != documentBinding.revision || text != documentBinding.text else {
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
        cancelInFlightWork()
        documentBinding = .empty
        query = nil
        session = nil
        pendingNavigationCommand = nil
        shouldActivateCurrentOnNextStep = false
        notifySessionDidChange()
    }

    // MARK: - Query / navigation

    public func setQuery(_ query: TextSearchQuery?) {
        self.query = query
        caretAnchorUTF16 = max(0, caretAnchorUTF16)
        scheduleMatch(reason: .query)
    }

    public func setCaretAnchor(_ utf16: Int) {
        caretAnchorUTF16 = max(0, utf16)
    }

    public func findNext() {
        // No navigation from a stale or in-flight session (cleared at scheduleMatch).
        guard var session else { return }
        if shouldActivateCurrentOnNextStep {
            shouldActivateCurrentOnNextStep = false
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
        guard var session else { return }
        if shouldActivateCurrentOnNextStep {
            shouldActivateCurrentOnNextStep = false
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
        shouldActivateCurrentOnNextStep = false
        emitNavigation(for: session?.currentMatch)
        notifySessionDidChange()
    }

    public func cancelInFlightWork() {
        // Count supersession of either the debounce admission or a running match worker.
        // Debounce cancel is the common rapid-typing path (matchTask often still nil).
        if debounceTask != nil || matchTask != nil {
            cancelledMatchCount &+= 1
        }
        debounceTask?.cancel()
        debounceTask = nil
        matchTask?.cancel()
        matchTask = nil
        // Advance the fence so a detached worker that still finishes cannot apply.
        // scheduleMatch will increment again when it starts a new generation — double
        // advance is fine and keeps cancel-only callers safe.
        queryGeneration &+= 1
    }

    // MARK: - Private

    private func clearSessionKeepingQuery() {
        session = nil
        pendingNavigationCommand = nil
        shouldActivateCurrentOnNextStep = false
    }

    private func scheduleMatch(reason: EditorFindScheduleReason) {
        cancelInFlightWork()
        queryGeneration &+= 1
        let generation = queryGeneration
        let binding = documentBinding
        let query = query
        let anchor = caretAnchorUTF16
        let debounce = debounceNanoseconds
        // Capture ordinal before invalidating session (edit preserves it when still valid).
        let preferredOrdinal: Int? = reason == .edit ? session?.currentOrdinal : nil
        let shouldNavigate = reason.emitsNavigationOnCompletion

        // Drop the previous session immediately so next/previous/activate during debounce
        // cannot navigate ranges from a superseded query or document revision.
        session = nil
        pendingNavigationCommand = nil
        shouldActivateCurrentOnNextStep = false
        notifySessionDidChange()

        guard let query, !query.pattern.isEmpty else {
            session = query.map { EditorFindSession.empty(query: $0, caretAnchorUTF16: anchor) }
            if shouldNavigate {
                pendingNavigationCommand = nil
            }
            notifySessionDidChange()
            return
        }

        let fence = EditorFindMatchFence(
            documentIdentity: binding.identity,
            sourceRevision: binding.revision,
            queryGeneration: generation
        )

        debounceTask = Task { @MainActor [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard !Task.isCancelled, let self else { return }
            runMatch(
                Work(
                    fence: fence,
                    text: binding.text,
                    query: query,
                    caretAnchor: anchor,
                    preferredOrdinal: preferredOrdinal,
                    shouldNavigate: shouldNavigate
                )
            )
        }
    }

    private struct Work {
        let fence: EditorFindMatchFence
        let text: String
        let query: TextSearchQuery
        let caretAnchor: Int
        let preferredOrdinal: Int?
        let shouldNavigate: Bool
    }

    private func runMatch(_ work: Work) {
        matchTask?.cancel()
        let hold = testMatchHold
        let forceMain = forceMainActorMatchForTesting

        matchTask = Task { @MainActor [weak self] in
            let result: (session: EditorFindSession, ranOffMain: Bool)
            if forceMain {
                if let hold {
                    await hold.waitIfHeld()
                }
                // Negative control path: same computation on the main actor.
                let session = EditorFindSession.search(
                    in: work.text,
                    query: work.query,
                    caretAnchorUTF16: work.caretAnchor,
                    preferredOrdinal: work.preferredOrdinal
                )
                result = (session, Self.currentlyOffMainThread())
            } else {
                result = await Task.detached(priority: .userInitiated) {
                    // Detached does not inherit Task cancellation; engine has no cancel points.
                    // Stale results are dropped at apply time via the fence (not by interrupting
                    // the engine).
                    if let hold {
                        await hold.waitIfHeld()
                    }
                    let session = EditorFindSession.search(
                        in: work.text,
                        query: work.query,
                        caretAnchorUTF16: work.caretAnchor,
                        preferredOrdinal: work.preferredOrdinal
                    )
                    return (session, EditorFindController.currentlyOffMainThread())
                }.value
            }

            // Do not skip apply on Task.isCancelled: a superseded worker still fence-drops
            // so droppedStaleMatchCount remains a real signal. Only `self` lifetime ends apply.
            guard let self else { return }
            lastMatchRanOffMain = result.ranOffMain
            applyMatchResult(
                result.session,
                fence: work.fence,
                shouldNavigate: work.shouldNavigate
            )
        }
    }

    private func applyMatchResult(
        _ newSession: EditorFindSession,
        fence: EditorFindMatchFence,
        shouldNavigate: Bool
    ) {
        let current = EditorFindMatchFence(
            documentIdentity: documentBinding.identity,
            sourceRevision: documentBinding.revision,
            queryGeneration: queryGeneration
        )
        guard current == fence else {
            droppedStaleMatchCount &+= 1
            return
        }
        completedMatchCount &+= 1
        session = newSession
        if shouldNavigate {
            shouldActivateCurrentOnNextStep = false
            emitNavigation(for: newSession.currentMatch)
        } else {
            // Counter-only recompute: first explicit next/previous activates current match
            // instead of stepping past the anchor-resolved ordinal.
            shouldActivateCurrentOnNextStep = newSession.currentMatch != nil
        }
        notifySessionDidChange()
    }

    private func emitNavigation(for match: TextSearchMatch?) {
        guard let match,
              let identity = documentBinding.identity
        else {
            return
        }
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
            selection: match.range
        )
        pendingNavigationCommand = .navigate(request)
    }

    private func notifySessionDidChange() {
        onSessionDidChange?()
    }

    /// Synchronous, nonisolated probe: true when the calling thread is not the main thread.
    /// Uses `pthread_main_np` so it is valid from async/detached contexts (unlike
    /// `Thread.isMainThread` under Swift 6 async unavailability).
    private nonisolated static func currentlyOffMainThread() -> Bool {
        pthread_main_np() == 0
    }
}
