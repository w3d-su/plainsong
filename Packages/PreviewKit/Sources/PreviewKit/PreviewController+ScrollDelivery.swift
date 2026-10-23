import Foundation

public extension PreviewController {
    func setPresentedDocumentIdentifier(_ identifier: String?) {
        presentedDocumentIdentifier = identifier
        scrollDeliveryState.presentedDocumentDidChange(to: identifier)
    }

    /// Without a `documentIdentifier` or completion this is editor viewport traffic (one call
    /// per scrolled frame): one such scroll is in flight at a time and the newest waiting
    /// line replaces older ones, so a busy WebContent process gets the latest position
    /// instead of a backlog. A document-bound navigation keeps the render barrier below and
    /// discards waiting viewport traffic, which would otherwise scroll back over it.
    func scrollToLine(
        _ line: Int,
        animated: Bool,
        documentIdentifier: String? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let payload = ScrollToLinePayload(line: line, animated: animated)
        guard let documentIdentifier else {
            if let completion {
                send(.scrollToLine(payload), completion: completion)
            } else {
                sendViewportScroll(payload)
            }
            return
        }

        viewportScrollQueue.pending = nil
        let delivery = scrollDeliveryState.requestScroll(
            payload: payload,
            documentIdentifier: documentIdentifier,
            isReady: isReady,
            completion: completion
        )
        if let delivery {
            send(.scrollToLine(delivery.payload), completion: delivery.completion)
        }
    }

    internal func flushPendingScrollDeliveryIfReady() {
        guard let delivery = scrollDeliveryState.takeDeliverable(isReady: isReady) else { return }
        viewportScrollQueue.pending = nil
        send(.scrollToLine(delivery.payload), completion: delivery.completion)
    }

    private func sendViewportScroll(_ payload: ScrollToLinePayload) {
        guard !viewportScrollQueue.isInFlight else {
            viewportScrollQueue.pending = payload
            return
        }
        viewportScrollQueue.isInFlight = true
        let generation = viewportScrollQueue.generation
        send(.scrollToLine(payload)) { [weak self] _ in
            self?.viewportScrollDidFinish(generation: generation)
        }
    }

    private func viewportScrollDidFinish(generation: UInt64) {
        // A reset (WebContent termination, invalidation) started a new generation; a late
        // completion from before it must not release the new generation's slot.
        guard viewportScrollQueue.generation == generation else { return }
        viewportScrollQueue.isInFlight = false
        guard let next = viewportScrollQueue.pending else { return }
        viewportScrollQueue.pending = nil
        sendViewportScroll(next)
    }
}

/// Editor viewport scroll traffic: one `scrollToLine` in flight, the newest line waiting.
struct PreviewViewportScrollQueue {
    var isInFlight = false
    var pending: ScrollToLinePayload?
    var generation: UInt64 = 0

    /// Drops the in-flight slot and anything waiting, and fences off late completions.
    mutating func reset() {
        isInFlight = false
        pending = nil
        generation &+= 1
    }
}

@MainActor
struct PreviewScrollDeliveryState {
    struct Delivery {
        let payload: ScrollToLinePayload
        let documentIdentifier: String
        var requiredRenderID: Int?
        let completion: (@MainActor (Bool) -> Void)?
    }

    private var pendingDelivery: Delivery?
    private var latestRequestedRenderID = -1
    private var latestRequestedDocumentIdentifier: String?
    private var latestCompletedRenderID = -1

    /// One shared barrier for export and scroll; a newer submitted render invalidates it.
    var completedRenderID: Int? {
        latestRequestedRenderID >= 0 && latestCompletedRenderID == latestRequestedRenderID
            ? latestCompletedRenderID : nil
    }

    mutating func presentedDocumentDidChange(to documentIdentifier: String?) {
        guard let pendingDelivery,
              pendingDelivery.documentIdentifier != documentIdentifier
        else {
            return
        }
        failPendingDelivery()
    }

    mutating func registerRender(_ renderID: Int, documentIdentifier: String?) {
        latestRequestedRenderID = renderID
        latestRequestedDocumentIdentifier = documentIdentifier
        guard var pendingDelivery else { return }
        guard pendingDelivery.documentIdentifier == documentIdentifier else {
            if pendingDelivery.requiredRenderID != nil {
                failPendingDelivery()
            }
            return
        }

        // A newer render for the same document supersedes the pending presentation.
        // Carry the latest navigation forward so it cannot run against an older DOM.
        pendingDelivery.requiredRenderID = renderID
        self.pendingDelivery = pendingDelivery
    }

    mutating func recordRenderCompletion(_ renderID: Int) -> Bool {
        guard renderID >= latestRequestedRenderID else { return false }
        latestCompletedRenderID = max(latestCompletedRenderID, renderID)
        return true
    }

    mutating func requestScroll(
        payload: ScrollToLinePayload,
        documentIdentifier: String,
        isReady: Bool,
        completion: (@MainActor (Bool) -> Void)?
    ) -> Delivery? {
        failPendingDelivery()
        let delivery = Delivery(
            payload: payload,
            documentIdentifier: documentIdentifier,
            requiredRenderID: latestRequestedDocumentIdentifier == documentIdentifier
                ? latestRequestedRenderID
                : nil,
            completion: completion
        )
        guard !canDeliver(delivery, isReady: isReady) else { return delivery }
        pendingDelivery = delivery
        return nil
    }

    mutating func takeDeliverable(isReady: Bool) -> Delivery? {
        guard let pendingDelivery, canDeliver(pendingDelivery, isReady: isReady) else { return nil }
        self.pendingDelivery = nil
        return pendingDelivery
    }

    mutating func failPendingDelivery() {
        guard let pendingDelivery else { return }
        self.pendingDelivery = nil
        pendingDelivery.completion?(false)
    }

    private func canDeliver(_ delivery: Delivery, isReady: Bool) -> Bool {
        guard isReady,
              let requiredRenderID = delivery.requiredRenderID,
              delivery.documentIdentifier == latestRequestedDocumentIdentifier,
              requiredRenderID == latestRequestedRenderID
        else {
            return false
        }
        return completedRenderID == requiredRenderID
    }
}
