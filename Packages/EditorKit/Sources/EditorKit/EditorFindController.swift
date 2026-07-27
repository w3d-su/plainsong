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

/// Fence token for an in-flight match computation.
private struct EditorFindMatchFence: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let sourceRevision: UInt64
    let queryGeneration: UInt64
}

/// Off-main, debounced, revision-fenced in-document find controller (PR B).
///
/// Match work never runs on the typing path. Navigation is emitted only as
/// `EditorNavigationCommand` values with fresh monotonic IDs. Find never mutates source.
@MainActor
public final class EditorFindController {
    public private(set) var session: EditorFindSession?
    public private(set) var pendingNavigationCommand: EditorNavigationCommand?
    public private(set) var documentBinding: EditorFindDocumentBinding
    public private(set) var query: TextSearchQuery?
    public private(set) var caretAnchorUTF16: Int = 0
    public private(set) var queryGeneration: UInt64 = 0
    public private(set) var lastMatchRanOffMain = false
    public private(set) var completedMatchCount = 0
    public private(set) var cancelledMatchCount = 0
    public private(set) var droppedStaleMatchCount = 0

    /// Debounce before off-main match work. Tests may set to 0.
    public var debounceNanoseconds: UInt64 = 150_000_000

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

    /// Rebinds to a new document identity/revision/text: cancel, clear, re-run.
    public func rebindDocument(_ binding: EditorFindDocumentBinding) {
        let identityChanged = binding.identity != documentBinding.identity
        documentBinding = binding
        if identityChanged {
            clearSessionKeepingQuery()
        }
        scheduleMatch(reason: .rebind)
    }

    /// Edit invalidation: same identity, newer revision/text → recompute.
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
        debounceTask?.cancel()
        debounceTask = nil
        if matchTask != nil {
            cancelledMatchCount &+= 1
        }
        matchTask?.cancel()
        matchTask = nil
    }

    // MARK: - Private

    private enum ScheduleReason {
        case query
        case edit
        case rebind
    }

    private func clearSessionKeepingQuery() {
        session = nil
        pendingNavigationCommand = nil
    }

    private func scheduleMatch(reason _: ScheduleReason) {
        cancelInFlightWork()
        queryGeneration &+= 1
        let generation = queryGeneration
        let binding = documentBinding
        let query = query
        let anchor = caretAnchorUTF16
        let debounce = debounceNanoseconds

        guard let query, !query.pattern.isEmpty else {
            session = query.map { EditorFindSession.empty(query: $0, caretAnchorUTF16: anchor) }
            pendingNavigationCommand = nil
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
            runMatch(fence: fence, text: binding.text, query: query, caretAnchor: anchor)
        }
    }

    private func runMatch(
        fence: EditorFindMatchFence,
        text: String,
        query: TextSearchQuery,
        caretAnchor: Int
    ) {
        matchTask?.cancel()
        matchTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                // Off the main actor: TextSearchEngine is synchronous and can exceed
                // the §12 typing budget on large documents (WS4B: 512 KiB < 150 ms Debug).
                let session = EditorFindSession.search(
                    in: text,
                    query: query,
                    caretAnchorUTF16: caretAnchor
                )
                return (session, true)
            }.value

            guard !Task.isCancelled, let self else { return }
            lastMatchRanOffMain = result.1
            applyMatchResult(result.0, fence: fence)
        }
    }

    private func applyMatchResult(_ newSession: EditorFindSession, fence: EditorFindMatchFence) {
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
        emitNavigation(for: newSession.currentMatch)
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
}
