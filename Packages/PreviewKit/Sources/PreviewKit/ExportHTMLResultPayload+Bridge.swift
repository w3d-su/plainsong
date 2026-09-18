import CoreFoundation
import Foundation

extension ExportHTMLResultPayload {
    /// Mirrors the Codable v6 schema, without copying a large HTML string through JSON.
    init?(bridgeBody: Any?) {
        guard let body = bridgeBody as? [String: Any],
              let exportID = Self.integer(body["exportID"]),
              let renderID = Self.integer(body["renderID"]),
              let state = body["state"] as? [String: Any],
              let kind = state["kind"] as? String
        else { return nil }
        let result: ExportHTMLResultState
        switch kind {
        case "ready":
            guard let html = state["html"] as? String else { return nil }
            result = .ready(html: html)
        case "failed":
            guard let reason = state["reason"] as? String else { return nil }
            result = .failed(reason: reason)
        case "resourcesNeeded":
            guard let entries = state["resources"] as? [[String: Any]] else { return nil }
            var resources: [ExportResourceDescriptor] = []
            for entry in entries {
                guard let resourceID = entry["resourceID"] as? String,
                      let rawKind = entry["kind"] as? String,
                      let kind = ExportResourceKind(rawValue: rawKind),
                      let src = entry["src"] as? String
                else { return nil }
                resources.append(ExportResourceDescriptor(resourceID: resourceID, kind: kind, src: src))
            }
            result = .resourcesNeeded(resources: resources)
        default:
            return nil
        }
        self.init(exportID: exportID, renderID: renderID, state: result)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue),
              integer >= 0
        else { return nil }
        return integer
    }
}
