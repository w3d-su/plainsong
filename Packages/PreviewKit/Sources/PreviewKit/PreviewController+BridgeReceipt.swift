import CoreFoundation
import Foundation
@preconcurrency import WebKit

extension PreviewController: WKScriptMessageHandler {
    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge" else { return }
        receiveBridgeBody(message.body)
    }

    /// Reads typed fields straight from WebKit's Foundation body. Export HTML can be many
    /// MiB and the others arrive per scroll frame, so none of them round-trips through
    /// `JSONSerialization` and a fresh `JSONDecoder` on the main actor.
    func receiveBridgeBody(_ body: Any) {
        guard !isInvalidated else { return }
        if let envelope = body as? [String: Any], envelope["name"] as? String == "exportHTMLResult" {
            if let payload = ExportHTMLResultPayload(bridgeBody: envelope["payload"]) {
                handleExportHTMLResult(payload)
            }
            return
        }
        guard let bridgeMessage = BridgeMessage(inboundBridgeBody: body) else { return }
        receive(bridgeMessage)
    }
}

extension BridgeMessage {
    /// The JavaScript-to-Swift messages other than `exportHTMLResult` (which has its own
    /// reader), accepting exactly what the Codable decoder accepts from the same body:
    /// integers must be non-Boolean whole numbers, Booleans must be Booleans, extra keys
    /// are ignored. Swift-to-JavaScript names are not inbound and read as nil.
    init?(inboundBridgeBody body: Any) {
        guard let envelope = body as? [String: Any],
              let name = envelope["name"] as? String,
              let payload = envelope["payload"] as? [String: Any]
        else { return nil }
        let field = BridgeBodyFields(payload)

        let message: BridgeMessage? = switch BridgeMessageName(rawValue: name) {
        case .ready:
            field.integer("protocolVersion").map { .ready(ReadyPayload(protocolVersion: $0)) }
        case .renderComplete:
            field.renderComplete.map(BridgeMessage.renderComplete)
        case .previewScrolled:
            field.integer("topVisibleLine").map { .previewScrolled(PreviewScrolledPayload(topVisibleLine: $0)) }
        case .linkClicked:
            (payload["href"] as? String).map { .linkClicked(LinkClickedPayload(href: $0)) }
        case .checkboxToggled:
            field.checkboxToggled.map(BridgeMessage.checkboxToggled)
        case .render, .scrollToLine, .setTheme, .exportHTML, .exportHTMLResult, nil:
            nil
        }
        guard let message else { return nil }
        self = message
    }
}

private struct BridgeBodyFields {
    let payload: [String: Any]

    init(_ payload: [String: Any]) {
        self.payload = payload
    }

    func integer(_ key: String) -> Int? {
        guard let number = payload[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return Int(exactly: number.doubleValue)
    }

    func boolean(_ key: String) -> Bool? {
        guard let number = payload[key] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    var renderComplete: RenderCompletePayload? {
        guard let renderID = integer("renderID"),
              let version = integer("version"),
              let blockCount = integer("blockCount")
        else { return nil }
        return RenderCompletePayload(renderID: renderID, version: version, blockCount: blockCount)
    }

    var checkboxToggled: CheckboxToggledPayload? {
        guard let renderID = integer("renderID"),
              let line = integer("line"),
              let checked = boolean("checked"),
              let version = integer("version")
        else { return nil }
        return CheckboxToggledPayload(renderID: renderID, line: line, checked: checked, version: version)
    }
}
