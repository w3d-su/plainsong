import Foundation
import MarkdownCore

extension PreviewController: IOSPreviewControlling, PreviewAssetAccessChecking {
    public func render(
        _ snapshot: DocumentSnapshot,
        identity: IOSDocumentIdentity,
        assetAccess: PreviewAssetAccessContext?
    ) {
        prepareIOSRender(snapshot, identity: identity, assetAccess: assetAccess)
    }

    public func setRemoteImagesAllowed(_ allowed: Bool) {
        setAllowsRemoteImages(allowed)
    }

    public func scrollToLine(_ line: Int) {
        scrollToLine(line, animated: false)
    }

    public func observe(
        _ handler: @escaping @MainActor (IOSPreviewEvent) -> Void
    ) -> any IOSObservation {
        eventHub.add(handler)
    }

    public func isCurrent(_ context: PreviewAssetAccessContext) -> Bool {
        assetSchemeHandler.isCurrent(context)
    }

    func emitPreviewEvent(_ event: IOSPreviewEvent) {
        guard !isInvalidated else { return }
        eventHub.emit(event)
    }
}

@MainActor
final class PreviewEventObservation: IOSObservation {
    private var handler: (@MainActor (IOSPreviewEvent) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    init(_ handler: @escaping @MainActor (IOSPreviewEvent) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
        onCancel?()
        onCancel = nil
    }

    func emit(_ event: IOSPreviewEvent) {
        handler?(event)
    }
}

@MainActor
final class PreviewEventHub {
    private var observations: [ObjectIdentifier: PreviewEventObservation] = [:]

    func add(_ handler: @escaping @MainActor (IOSPreviewEvent) -> Void) -> PreviewEventObservation {
        let observation = PreviewEventObservation(handler)
        let key = ObjectIdentifier(observation)
        observations[key] = observation
        observation.onCancel = { [weak self] in
            self?.observations.removeValue(forKey: key)
        }
        return observation
    }

    func emit(_ event: IOSPreviewEvent) {
        for observation in observations.values {
            observation.emit(event)
        }
    }
}
