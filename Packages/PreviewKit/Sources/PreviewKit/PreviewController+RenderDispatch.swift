import Foundation
import MarkdownCore
@preconcurrency import WebKit

/// One render waiting to be sent. Theme and remote-image policy are read when it is sent,
/// so a `setTheme` that arrives while it waits is not undone by an older payload.
struct PreviewRenderRequest {
    let change: DocumentTextChange
    let renderID: Int
    let baseDir: String?
    let assetRootID: String
}

/// Single-flight render dispatch (`docs/decisions/2026-10-22-preview-render-single-flight.md`).
///
/// JavaScript learns that a render is stale only after an `await`, so every render already
/// queued in WebKit runs the whole unified pipeline. Keeping one render in flight and
/// replacing the pending one collapses a backlog to the newest text.
struct PreviewRenderDispatch {
    var inFlightRenderID: Int?
    var pending: PreviewRenderRequest?
    var watchdogTask: Task<Void, Never>?
    /// The newest render handed to JavaScript, kept after it completes: the page shows it,
    /// so a reloaded page after a WebContent termination needs it again.
    var lastSent: PreviewRenderRequest?
}

/// The presentation a session render last submitted. A repeat with the same key is
/// redundant: the DOM already shows (or is about to show) exactly this. The session is
/// held weakly and compared by identity, so a new session that reuses a released one's
/// address never matches.
struct PreviewRenderSubmission {
    struct Key: Equatable {
        let version: Int
        let fileKind: FileKind
        let fileURL: URL?
        let documentIdentifier: String?
        let workspaceAssetRootURL: URL?
        let theme: String
        let allowRemoteImages: Bool
    }

    weak var session: DocumentSession?
    let renderID: Int
    let key: Key
}

extension PreviewController {
    func renderSubmission(
        _ change: DocumentTextChange,
        session: DocumentSession,
        renderID: Int
    ) -> PreviewRenderSubmission {
        PreviewRenderSubmission(session: session, renderID: renderID, key: renderSubmissionKey(change))
    }

    func isAlreadySubmitted(_ change: DocumentTextChange, session: DocumentSession) -> Bool {
        guard let lastSubmittedRender, lastSubmittedRender.session === session else { return false }
        return lastSubmittedRender.key == renderSubmissionKey(change)
    }

    private func renderSubmissionKey(_ change: DocumentTextChange) -> PreviewRenderSubmission.Key {
        PreviewRenderSubmission.Key(
            version: change.version,
            fileKind: change.fileKind,
            fileURL: change.fileURL,
            documentIdentifier: presentedDocumentIdentifier
                ?? change.fileURL?.standardizedFileURL.absoluteString,
            workspaceAssetRootURL: workspaceAssetRootURL,
            theme: theme,
            allowRemoteImages: allowRemoteImages
        )
    }

    /// The newest request replaces any older one still waiting; it is sent at once when the
    /// bridge is ready and nothing is in flight.
    func enqueueRender(_ request: PreviewRenderRequest) {
        renderDispatch.pending = request
        retryExhaustedRecoveryForNewRender()
        dispatchPendingRenderIfIdle()
    }

    /// Sends the pending render when the bridge is ready and nothing is in flight.
    func dispatchPendingRenderIfIdle() {
        guard isReady, !isInvalidated, renderDispatch.inFlightRenderID == nil,
              let request = renderDispatch.pending
        else { return }
        renderDispatch.pending = nil
        renderDispatch.inFlightRenderID = request.renderID
        renderDispatch.lastSent = request
        startRenderWatchdog(for: request.renderID)

        let payload = RenderPayload(
            change: request.change,
            renderID: request.renderID,
            theme: theme,
            allowRemoteImages: allowRemoteImages,
            baseDir: request.baseDir,
            assetRootID: request.assetRootID
        )
        let renderID = request.renderID
        sendRender(payload) { [weak self] delivered in
            guard !delivered else { return }
            self?.renderDeliveryFailed(renderID)
        }
    }

    /// Releases the in-flight slot for `renderID` (or anything older still marked in
    /// flight) and sends the pending render, if any.
    func renderDidSettle(_ renderID: Int) {
        guard let inFlightRenderID = renderDispatch.inFlightRenderID,
              renderID >= inFlightRenderID
        else { return }
        renderDispatch.inFlightRenderID = nil
        renderDispatch.watchdogTask?.cancel()
        renderDispatch.watchdogTask = nil
        dispatchPendingRenderIfIdle()
    }

    /// `keepingPending` is false only on invalidation; a terminated WebContent process
    /// keeps the newest request so a reloaded page can still show it.
    func resetRenderDispatch(keepingPending: Bool) {
        renderDispatch.watchdogTask?.cancel()
        let pending = keepingPending ? renderDispatch.pending : nil
        renderDispatch = PreviewRenderDispatch(pending: pending)
        lastSubmittedRender = nil
    }

    /// JavaScript never saw the render, so no `renderComplete` will come and the DOM does
    /// not show it: a later identical request must not be suppressed as a duplicate.
    private func renderDeliveryFailed(_ renderID: Int) {
        if lastSubmittedRender?.renderID == renderID {
            lastSubmittedRender = nil
        }
        renderDidSettle(renderID)
    }

    private func startRenderWatchdog(for renderID: Int) {
        renderDispatch.watchdogTask?.cancel()
        let timeout = renderWatchdogNanoseconds
        renderDispatch.watchdogTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            self?.renderDidSettle(renderID)
        }
    }

    /// The document text goes to WebKit as a string argument: no JSON encoding, no copy into
    /// a script source, and no JavaScript parse of the whole text. The message is the one
    /// `BridgeMessage.render` encodes, so the bridge protocol is unchanged.
    private func sendRender(_ payload: RenderPayload, completion: @escaping @MainActor (Bool) -> Void) {
        if let bridgeTransportOverrideForTesting {
            bridgeTransportOverrideForTesting(.render(payload), completion)
            return
        }
        webView.callAsyncJavaScript(
            "window.PlainsongBridge.receive(message);",
            arguments: ["message": Self.renderMessageBody(payload)],
            in: nil,
            in: .page
        ) { result in
            if case .failure = result {
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    /// `BridgeMessage.render(payload)` as Foundation objects. A nil `baseDir` is omitted,
    /// as `JSONEncoder` omits it; Booleans stay `CFBoolean` so JavaScript sees `true`/`false`.
    nonisolated static func renderMessageBody(_ payload: RenderPayload) -> [String: Any] {
        var body: [String: Any] = [
            "renderID": payload.renderID,
            "version": payload.version,
            "fileKind": payload.fileKind.rawValue,
            "text": payload.text,
            "assetRootID": payload.assetRootID,
            "theme": payload.theme,
            "allowRemoteImages": payload.allowRemoteImages,
        ]
        if let baseDir = payload.baseDir {
            body["baseDir"] = baseDir
        }
        return ["name": BridgeMessageName.render.rawValue, "payload": body]
    }
}

struct PreviewAssetContextCacheEntry {
    let fileURL: URL?
    let workspaceRootURL: URL?
    let context: PreviewAssetContext
}

extension PreviewController {
    /// `assetContext(fileURL:workspaceRootURL:)` resolves symlinks on two URLs; every
    /// keystroke's render asked the same question, so the answer is kept per pair. The
    /// asset handler still checks containment and symlinks on every request (§7.1).
    func cachedAssetContext(fileURL: URL?) -> PreviewAssetContext {
        if let assetContextCache,
           assetContextCache.fileURL == fileURL,
           assetContextCache.workspaceRootURL == workspaceAssetRootURL
        {
            return assetContextCache.context
        }
        let context = Self.assetContext(fileURL: fileURL, workspaceRootURL: workspaceAssetRootURL)
        assetContextCache = PreviewAssetContextCacheEntry(
            fileURL: fileURL,
            workspaceRootURL: workspaceAssetRootURL,
            context: context
        )
        return context
    }
}
