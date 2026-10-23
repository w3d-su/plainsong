import EditorKit
import PreviewKit
import SwiftUI

@MainActor
final class EditorPreviewScrollCoordinator: ObservableObject {
    /// Monotonic nanoseconds.
    typealias Clock = @MainActor () -> UInt64

    /// The scroll-owner token decays this long after its last claim (agent.md §8).
    static let ownerDecayNanoseconds: UInt64 = 100_000_000

    let editorProxy = EditorScrollProxy()

    private weak var previewController: PreviewController?
    private(set) var previewScrollDeliveryReceipt: PreviewScrollDeliveryReceipt?
    private var claimedScrollOwner: ScrollOwner = .none
    private var scrollOwnerDeadline: UInt64 = 0
    private var isEditorScrollForwardingEnabled = false
    private var previewScrollRequestID: UInt64 = 0
    private var previewScrollDeliveryOverride:
        ((Int, Bool, String?, @escaping @MainActor (Bool) -> Void) -> Void)?
    private var now: Clock = { DispatchTime.now().uptimeNanoseconds }

    /// The owner claimed within the last `ownerDecayNanoseconds`, else `.none`. A timestamp
    /// comparison: scroll events arrive once per frame, and a decay `Task` per event was
    /// the cost this replaces.
    var scrollOwner: ScrollOwner {
        now() < scrollOwnerDeadline ? claimedScrollOwner : .none
    }

    #if DEBUG
        weak static var latestDebugInstance: EditorPreviewScrollCoordinator?
    #endif

    init() {
        editorProxy.onScrollIntent = { [weak self] intent in
            self?.handleEditorScrollIntent(intent)
        }
        #if DEBUG
            Self.latestDebugInstance = self
        #endif
    }

    func connect(previewController: PreviewController) {
        self.previewController = previewController
    }

    func setEditorScrollForwardingEnabled(_ isEnabled: Bool) {
        isEditorScrollForwardingEnabled = isEnabled
    }

    func previewScrolled(to line: Int) {
        guard scrollOwner != .editor else { return }

        setScrollOwner(.preview)
        editorProxy.scrollToLine(line)
    }

    private func handleEditorScrollIntent(_ intent: EditorScrollIntent) {
        switch intent {
        case let .viewportChanged(line):
            guard isEditorScrollForwardingEnabled, scrollOwner != .preview else { return }
            setScrollOwner(.editor)
            deliverViewportScroll(to: line)
        case let .navigation(line, documentIdentity):
            // Explicit navigation is presentation consistency, not typewriter sync. It
            // must reach a mounted preview even while that preference is disabled or a
            // preview-owned scroll token is still inside its 100 ms decay window. Re-arm
            // that token so a nearly-expired token cannot release it before the queued
            // editor echo arrives and scrolls the preview back over this intent.
            if scrollOwner == .preview {
                setScrollOwner(.preview)
            }
            deliverNavigationScroll(
                to: line,
                documentIdentifier: documentIdentity.rawValue
            )
        }
    }

    /// Per-frame editor viewport traffic carries no completion and leaves no receipt:
    /// nothing waits on it, and the controller keeps one such scroll in flight with only
    /// the newest line waiting.
    private func deliverViewportScroll(to line: Int) {
        if let previewScrollDeliveryOverride {
            previewScrollDeliveryOverride(line, false, nil) { _ in }
        } else {
            previewController?.scrollToLine(line, animated: false)
        }
    }

    private func deliverNavigationScroll(to line: Int, documentIdentifier: String) {
        previewScrollRequestID &+= 1
        let requestID = previewScrollRequestID
        let ownerAtDispatch = scrollOwner
        let completion: @MainActor (Bool) -> Void = { [weak self] succeeded in
            guard let self, requestID == previewScrollRequestID else { return }
            previewScrollDeliveryReceipt = PreviewScrollDeliveryReceipt(
                requestID: requestID,
                line: line,
                documentIdentifier: documentIdentifier,
                ownerAtDispatch: ownerAtDispatch,
                succeeded: succeeded
            )
        }
        if let previewScrollDeliveryOverride {
            previewScrollDeliveryOverride(line, false, documentIdentifier, completion)
        } else if let previewController {
            previewController.scrollToLine(
                line,
                animated: false,
                documentIdentifier: documentIdentifier,
                completion: completion
            )
        } else {
            completion(false)
        }
    }

    func installPreviewScrollDeliveryOverrideForTesting(
        _ delivery: @escaping (Int, Bool, String?, @escaping @MainActor (Bool) -> Void) -> Void
    ) {
        previewScrollDeliveryOverride = delivery
    }

    func installClockForTesting(_ clock: @escaping Clock) {
        now = clock
    }

    private func setScrollOwner(_ owner: ScrollOwner) {
        claimedScrollOwner = owner
        scrollOwnerDeadline = now() &+ Self.ownerDecayNanoseconds
    }

    #if DEBUG
        var previewControllerForTesting: PreviewController? {
            previewController
        }
    #endif

    enum ScrollOwner: Equatable {
        case editor
        case preview
        case none
    }
}

struct PreviewScrollDeliveryReceipt: Equatable {
    let requestID: UInt64
    let line: Int
    let documentIdentifier: String?
    let ownerAtDispatch: EditorPreviewScrollCoordinator.ScrollOwner
    let succeeded: Bool
}
