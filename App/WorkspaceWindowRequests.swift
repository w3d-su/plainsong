import AppKit
import Foundation

/// File › New Window (WD3) and WD7's "otherwise a new window" (`docs/window-state-gates.md`
/// §5.2, §6.1).
///
/// SwiftUI creates the scene. The next workspace scene to appear takes the oldest waiting
/// request in `WindowFacadeHolder.init`, and the request's action runs on that scene's façade
/// once its window attaches. A request that no scene takes, or a scene whose window never
/// attaches, expires, so a lost open can never run in an unrelated window later.
@MainActor
final class WorkspaceWindowRequests {
    static let shared = WorkspaceWindowRequests()
    private static let timeout: Duration = .seconds(3)

    private struct Request {
        let id = UUID()
        /// Only a scene on this registry may take the request.
        weak var registry: AppDocumentRegistry?
        let action: ((AppState) -> Void)?
    }

    private struct Claim {
        weak var facade: AppState?
        let request: Request
    }

    private var waiting: [Request] = []
    private var claims: [ObjectIdentifier: Claim] = [:]

    private init() {}

    /// Whether a new workspace window can be opened for `registry`: some scene or command has
    /// installed SwiftUI's opener, and the scenes it opens belong to this registry. Hosted
    /// fixtures build their own registries, which no scene ever shows.
    func canOpenNewWindow(for registry: AppDocumentRegistry) -> Bool {
        WorkspaceSceneReopener.shared.sceneOpener != nil
            && WorkspaceSceneReopener.shared.knownOwner?.registry === registry
    }

    /// Opens a new workspace window on `registry`, then runs `action` on its façade when its
    /// window attaches. `opener` is SwiftUI's `openWindow` for the workspace group; without
    /// one, the opener a scene installed is used. Returns false, opening nothing, when no
    /// scene for `registry` can be opened.
    @discardableResult
    func openNewWindow(
        on registry: AppDocumentRegistry,
        opener: (() -> Void)? = nil,
        then action: ((AppState) -> Void)? = nil
    ) -> Bool {
        guard WorkspaceSceneReopener.shared.knownOwner?.registry === registry,
              let open = opener ?? WorkspaceSceneReopener.shared.sceneOpener
        else {
            return false
        }
        let request = Request(registry: registry, action: action)
        waiting.append(request)
        expire(request.id)
        open()
        return true
    }

    /// A new workspace scene takes the oldest waiting request for its registry.
    func claimNextRequest(for facade: AppState) {
        waiting.removeAll { $0.registry == nil }
        guard let index = waiting.firstIndex(where: { $0.registry === facade.registry }) else { return }
        claims = claims.filter { $0.value.facade != nil }
        claims[ObjectIdentifier(facade)] = Claim(facade: facade, request: waiting.remove(at: index))
    }

    /// `facade`'s window attached: run the request it took, once.
    func noteAttached(_ facade: AppState) {
        let identifier = ObjectIdentifier(facade)
        guard let claim = claims[identifier], claim.facade === facade else { return }
        claims[identifier] = nil
        claim.request.action?(facade)
    }

    var hasWaitingRequests: Bool {
        !waiting.isEmpty || claims.values.contains { $0.facade != nil }
    }

    #if DEBUG
        func resetForTesting() {
            waiting.removeAll()
            claims.removeAll()
        }
    #endif

    private func expire(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.timeout)
            self.waiting.removeAll { $0.id == id }
            self.claims = self.claims.filter { $0.value.request.id != id && $0.value.facade != nil }
        }
    }
}
