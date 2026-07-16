import Foundation
import MarkdownCore

@MainActor
extension AppState {
    @discardableResult
    func advanceSessionLifecycle(for session: DocumentSession) -> UInt64 {
        let identity = ObjectIdentifier(session)
        precondition(
            sessionLifecycleGenerations[identity, default: 0] < .max,
            "Session lifecycle generation exhausted"
        )
        sessionLifecycleGenerations[identity, default: 0] += 1
        return sessionLifecycleGenerations[identity, default: 0]
    }

    func currentSessionLifecycleGeneration(for session: DocumentSession) -> UInt64 {
        sessionLifecycleGenerations[ObjectIdentifier(session), default: 0]
    }
}
