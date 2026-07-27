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
/// can be made deterministic. Not used in production.
public final class EditorFindMatchHold: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    public func waitIfHeld() async {
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

    public func release() {
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

    /// Test seam: when true, match work runs on the main actor (for the off-main negative control).
    public var forceMainActorMatchForTesting = false

    /// Test seam: when set, the match worker awaits `waitIfHeld()` before searching.
    public var testMatchHold: EditorFindMatchHold?

    private var navigationSequence: UInt64 = 0
    private var matchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

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

    /// No document remains: cancel and clear session (F4b controller half).
    public func clearForNoDocument() {
        cancelInFlightWork()
        documentBinding = .empty
        session = nil
        pendingNavigationCommand = nil
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
        guard var session else { return }
        session = session.next()
        self.session = session
        emitNavigation(for: session.currentMatch)
    }

    public func findPrevious() {
        guard var session else { return }
        session = session.previous()
        self.session = session
        emitNavigation(for: session.currentMatch)
    }

    /// Re-activates the current match with a fresh navigation ID (F3).
    public func activateCurrentMatch() {
        emitNavigation(for: session?.currentMatch)
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
    }

    // MARK: - Private

    private func clearSessionKeepingQuery() {
        session = nil
        pendingNavigationCommand = nil
    }

    private func scheduleMatch(reason: EditorFindScheduleReason) {
        cancelInFlightWork()
        queryGeneration &+= 1
        let generation = queryGeneration
        let binding = documentBinding
        let query = query
        let anchor = caretAnchorUTF16
        let debounce = debounceNanoseconds
        // Edit preserves ordinal when the match still exists; query/rebind resolve from anchor.
        let preferredOrdinal: Int? = reason == .edit ? session?.currentOrdinal : nil
        let shouldNavigate = reason.emitsNavigationOnCompletion

        guard let query, !query.pattern.isEmpty else {
            session = query.map { EditorFindSession.empty(query: $0, caretAnchorUTF16: anchor) }
            if shouldNavigate {
                pendingNavigationCommand = nil
            }
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
            emitNavigation(for: newSession.currentMatch)
        }
    }

    private func emitNavigation(for match: TextSearchMatch?) {
        guard let match,
              let identity = documentBinding.identity
        else {
            return
        }
        navigationSequence &+= 1
        let request = EditorNavigationRequest(
            id: navigationSequence,
            documentIdentity: identity,
            selection: match.range
        )
        pendingNavigationCommand = .navigate(request)
    }

    /// Synchronous, nonisolated probe: true when the calling thread is not the main thread.
    /// Uses `pthread_main_np` so it is valid from async/detached contexts (unlike
    /// `Thread.isMainThread` under Swift 6 async unavailability).
    private nonisolated static func currentlyOffMainThread() -> Bool {
        pthread_main_np() == 0
    }
}
