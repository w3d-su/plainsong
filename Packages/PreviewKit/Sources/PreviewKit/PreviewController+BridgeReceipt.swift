import Foundation
@preconcurrency import WebKit

extension PreviewController: WKScriptMessageHandler {
    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge" else { return }
        receiveBridgeBody(message.body)
    }

    /// Export HTML can be many MiB: consume typed dictionary fields directly instead
    /// of serializing and decoding the whole string on the WebKit main-actor callback.
    func receiveBridgeBody(_ body: Any) {
        guard !isInvalidated else { return }
        if let envelope = body as? [String: Any], envelope["name"] as? String == "exportHTMLResult" {
            if let payload = ExportHTMLResultPayload(bridgeBody: envelope["payload"]) {
                handleExportHTMLResult(payload)
            }
            return
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let bridgeMessage = try? JSONDecoder().decode(BridgeMessage.self, from: data)
        else { return }

        receive(bridgeMessage)
    }
}
