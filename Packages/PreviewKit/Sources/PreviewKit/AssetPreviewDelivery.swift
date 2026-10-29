import Foundation
import MarkdownCore
import OSLog

enum AssetDeliveryResponse {
    typealias HTTPResponseFactory = (URL, [String: String]) -> HTTPURLResponse?

    /// Nil only when an asset that needs headers (an admitted SVG) cannot get them. The
    /// caller fails the task: an SVG is never served without its CSP and `nosniff`.
    static func make(
        url: URL,
        asset: AssetURLPolicyResult,
        httpResponse: HTTPResponseFactory = { url, headers in
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
        }
    ) -> URLResponse? {
        if let policy = asset.contentSecurityPolicy {
            return httpResponse(url, [
                "Content-Type": asset.mimeType == SVGImageValidator.mimeType
                    ? SVGImageValidator.contentType : asset.mimeType,
                "Content-Length": String(asset.data.count),
                "Content-Security-Policy": policy,
                "X-Content-Type-Options": "nosniff",
            ])
        }
        return URLResponse(
            url: url,
            mimeType: asset.mimeType,
            expectedContentLength: asset.data.count,
            textEncodingName: nil
        )
    }
}

enum SVGAssetDiagnostics {
    private static let logger = Logger(subsystem: "app.plainsong", category: "SVGPreview")

    static func logRejection(_ reason: SVGImageRejection) {
        logger.debug("SVG rejected: \(String(describing: reason), privacy: .public)")
    }
}

extension AssetURLPolicy {
    /// Preview delivery. `loadAsset` stays raster-only so HTML export does not
    /// start accepting SVG in this gate.
    static func deliveredPreviewAsset(data: Data, fileURL: URL) throws -> AssetURLPolicyResult {
        guard isSVG(fileURL) else {
            return try deliveredAsset(data: data, fileURL: fileURL)
        }
        switch SVGImageValidator.admission(of: data) {
        case .admit:
            return AssetURLPolicyResult(
                mimeType: SVGImageValidator.mimeType,
                data: data,
                contentSecurityPolicy: SVGImageValidator.contentSecurityPolicy
            )
        case let .reject(.tooLarge(byteCount, maximumByteCount)):
            throw AssetURLPolicyError.fileTooLarge(
                actualBytes: Int64(byteCount),
                maxBytes: Int64(maximumByteCount)
            )
        case let .reject(rejection):
            throw AssetURLPolicyError.rejectedSVG(rejection)
        }
    }
}
