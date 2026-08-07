import EditorKit
import PreviewKit
import SwiftUI

@MainActor
final class EditorPreviewScrollCoordinator: ObservableObject {
    typealias OwnerDecayScheduler =
        (@escaping @MainActor () -> Void) -> Task<Void, Never>

    let editorProxy = EditorScrollProxy()

    private weak var previewController: PreviewController?
    private(set) var scrollOwner: ScrollOwner = .none
    private(set) var previewScrollDeliveryReceipt: PreviewScrollDeliveryReceipt?
    private var decayTask: Task<Void, Never>?
    private var isEditorScrollForwardingEnabled = false
    private var previewScrollRequestID: UInt64 = 0
    private var ownerDecayGeneration: UInt64 = 0
    private var previewScrollDeliveryOverride:
        ((Int, Bool, @escaping @MainActor (Bool) -> Void) -> Void)?
    private var ownerDecayScheduler: OwnerDecayScheduler

    #if DEBUG
        weak static var latestDebugInstance: EditorPreviewScrollCoordinator?
    #endif

    init() {
        ownerDecayScheduler = { completion in
            Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                completion()
            }
        }
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
            deliverPreviewScroll(to: line)
        case let .navigation(line):
            // Explicit navigation is presentation consistency, not typewriter sync. It
            // must reach a mounted preview even while that preference is disabled or a
            // preview-owned scroll token is still inside its 100 ms decay window. Re-arm
            // that token so a nearly-expired timer cannot release it before the queued
            // editor echo arrives and scrolls the preview back over this intent.
            if scrollOwner == .preview {
                setScrollOwner(.preview)
            }
            deliverPreviewScroll(to: line)
        }
    }

    private func deliverPreviewScroll(to line: Int) {
        previewScrollRequestID &+= 1
        let requestID = previewScrollRequestID
        let ownerAtDispatch = scrollOwner
        let completion: @MainActor (Bool) -> Void = { [weak self] succeeded in
            guard let self, requestID == previewScrollRequestID else { return }
            previewScrollDeliveryReceipt = PreviewScrollDeliveryReceipt(
                requestID: requestID,
                line: line,
                ownerAtDispatch: ownerAtDispatch,
                succeeded: succeeded
            )
        }
        if let previewScrollDeliveryOverride {
            previewScrollDeliveryOverride(line, false, completion)
        } else if let previewController {
            previewController.scrollToLine(line, animated: false, completion: completion)
        } else {
            completion(false)
        }
    }

    func installPreviewScrollDeliveryOverrideForTesting(
        _ delivery: @escaping (Int, Bool, @escaping @MainActor (Bool) -> Void) -> Void
    ) {
        previewScrollDeliveryOverride = delivery
    }

    func installOwnerDecaySchedulerForTesting(_ scheduler: @escaping OwnerDecayScheduler) {
        decayTask?.cancel()
        ownerDecayScheduler = scheduler
    }

    private func setScrollOwner(_ owner: ScrollOwner) {
        scrollOwner = owner
        decayTask?.cancel()
        ownerDecayGeneration &+= 1
        let generation = ownerDecayGeneration
        decayTask = ownerDecayScheduler { [weak self] in
            guard self?.ownerDecayGeneration == generation else { return }
            self?.scrollOwner = .none
        }
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
    let ownerAtDispatch: EditorPreviewScrollCoordinator.ScrollOwner
    let succeeded: Bool
}
