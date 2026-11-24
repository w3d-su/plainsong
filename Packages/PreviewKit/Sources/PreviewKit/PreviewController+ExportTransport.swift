import Foundation
import WebKit

extension PreviewController {
    /// The finalization request carries every embedded image as a data URI. It goes to
    /// WebKit as an argument, as a render does: no JSON encoding on the main actor, no
    /// copy into a script source, and no JavaScript parse of the whole payload. The
    /// message is the one `BridgeMessage.exportHTML` encodes, so the protocol is unchanged.
    func sendExportHTML(_ payload: ExportHTMLPayload, completion: @escaping @MainActor (Bool) -> Void) {
        if let bridgeTransportOverrideForTesting {
            bridgeTransportOverrideForTesting(.exportHTML(payload), completion)
            return
        }
        webView.callAsyncJavaScript(
            "window.PlainsongBridge.receive(message);",
            arguments: ["message": Self.exportHTMLMessageBody(payload)],
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

    /// `BridgeMessage.exportHTML(payload)` as Foundation objects. Nil fields are omitted,
    /// as `JSONEncoder` omits them.
    nonisolated static func exportHTMLMessageBody(_ payload: ExportHTMLPayload) -> [String: Any] {
        var body: [String: Any] = [
            "exportID": payload.exportID,
            "renderID": payload.renderID,
            "phase": payload.phase.rawValue,
            "resourceOutcomes": payload.resourceOutcomes.map(exportOutcomeBody),
        ]
        if let documentTitle = payload.documentTitle {
            body["documentTitle"] = documentTitle
        }
        return ["name": BridgeMessageName.exportHTML.rawValue, "payload": body]
    }

    private nonisolated static func exportOutcomeBody(_ outcome: ExportResourceOutcome) -> [String: Any] {
        var body: [String: Any] = [
            "resourceID": outcome.resourceID,
            "kind": outcome.kind.rawValue,
            "action": outcome.action.rawValue,
        ]
        if let dataURI = outcome.dataURI {
            body["dataURI"] = dataURI
        }
        if let dataURIFrom = outcome.dataURIFrom {
            body["dataURIFrom"] = dataURIFrom
        }
        if let reason = outcome.reason {
            body["reason"] = reason
        }
        return body
    }
}
