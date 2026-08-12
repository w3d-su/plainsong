import Foundation

public extension PreviewController {
    func setPresentedDocumentIdentifier(_ identifier: String?) {
        presentedDocumentIdentifier = identifier
        scrollDeliveryState.presentedDocumentDidChange(to: identifier)
    }

    func scrollToLine(
        _ line: Int,
        animated: Bool,
        documentIdentifier: String? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let payload = ScrollToLinePayload(line: line, animated: animated)
        guard let documentIdentifier else {
            send(.scrollToLine(payload), completion: completion)
            return
        }

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
        send(.scrollToLine(delivery.payload), completion: delivery.completion)
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
        return latestCompletedRenderID >= requiredRenderID
    }
}
