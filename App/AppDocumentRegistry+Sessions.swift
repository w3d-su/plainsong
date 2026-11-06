import Foundation
import MarkdownCore

/// A connected window, held weakly so the registry never keeps a closed window alive.
struct RegisteredWindowState {
    weak var window: WindowState?
}

/// Where a registry inventory takes its sessions from (`docs/window-state-gates.md` §3.4 I2).
/// An inventory lists its sources in the order it wants them; each session appears once.
enum RegistrySessionSource {
    /// Every connected window's document, untitled ones included.
    case windowDocuments
    /// Connected windows' documents that have a file URL.
    case fileBackedWindowDocuments
    /// The warm session cache, in its dictionary order.
    case warmCache
    case retired
    case editorBindings
    case editorInstallations
    /// Sessions a namespace-mutation recovery still holds, then its text-recovery sessions.
    case mutationRecovery
    /// Text-recovery sessions only.
    case textRecovery
}

/// The one session enumerator and warm-cache API (§3.4 I2). Ownership inventories, pruning,
/// autosave, termination, and search take their sessions from here, so a session that only a
/// second window shows is never missed.
@MainActor
extension AppDocumentRegistry {
    // MARK: Windows

    /// Adds `window` to every inventory. `AppState` connects the window's hooks first.
    func register(_ window: WindowState) {
        registeredWindows.removeAll { $0.window == nil || $0.window === window }
        registeredWindows.append(RegisteredWindowState(window: window))
    }

    /// Removes a closed sibling window from every inventory (`KeyWindowRouter.closeFacade`).
    func unregister(_ window: WindowState) {
        registeredWindows.removeAll { $0.window == nil || $0.window === window }
    }

    var connectedWindows: [WindowState] {
        registeredWindows.compactMap(\.window)
    }

    func isShownByAnyWindow(_ session: DocumentSession) -> Bool {
        connectedWindows.contains { $0.shownSession === session }
    }

    // MARK: Inventories

    func sessions(from sources: [RegistrySessionSource]) -> [DocumentSession] {
        var seen: Set<ObjectIdentifier> = []
        var sessions: [DocumentSession] = []
        func append(_ candidates: some Sequence<DocumentSession>) {
            for session in candidates where seen.insert(ObjectIdentifier(session)).inserted {
                sessions.append(session)
            }
        }
        for source in sources {
            switch source {
            case .windowDocuments:
                append(connectedWindows.map(\.shownSession))
            case .fileBackedWindowDocuments:
                append(connectedWindows.map(\.shownSession).filter { $0.fileURL != nil })
            case .warmCache:
                append(sessionCache.values)
            case .retired:
                append(retiredEditorDocumentSessions.values.map(\.session))
            case .editorBindings:
                append(editorDocumentBindingSessions.values)
            case .editorInstallations:
                append(editorBindingInstallations.values)
            case .mutationRecovery:
                append(workspaceMutationRecoveries.values.flatMap(\.remainingSessions))
                append(workspaceMutationTextRecoverySessions.values)
            case .textRecovery:
                append(workspaceMutationTextRecoverySessions.values)
            }
        }
        return sessions
    }

    func contains(_ session: DocumentSession, in sources: [RegistrySessionSource]) -> Bool {
        sessions(from: sources).contains { $0 === session }
    }

    // MARK: Warm cache

    func warmSession(at url: URL) -> DocumentSession? {
        sessionCache[url]
    }

    func setWarmSession(_ session: DocumentSession?, at url: URL) {
        sessionCache[url] = session
    }

    /// Clears `url` only when `session` is the warm session there.
    func removeWarmSession(_ session: DocumentSession, at url: URL) {
        if sessionCache[url] === session {
            sessionCache[url] = nil
        }
    }

    func removeAllWarmSessions() {
        sessionCache.removeAll()
    }

    func isWarmSession(_ session: DocumentSession, at url: URL) -> Bool {
        sessionCache[url] === session
    }

    func isWarmSession(_ session: DocumentSession) -> Bool {
        sessionCache.values.contains { $0 === session }
    }

    var warmSessionURLs: [URL] {
        Array(sessionCache.keys)
    }

    func warmSessionURLs(for session: DocumentSession) -> [URL] {
        sessionCache.compactMap { url, warmSession in warmSession === session ? url : nil }
    }

    /// Warm sessions with their URLs, for callers that order them.
    var warmSessionEntries: [(url: URL, session: DocumentSession)] {
        sessionCache.map { (url: $0.key, session: $0.value) }
    }
}
