import Foundation
import MarkdownCore

enum AssetDeliveryResponse {
    static func make(url: URL, asset: AssetURLPolicyResult) -> URLResponse {
        if let policy = asset.contentSecurityPolicy,
           let response = HTTPURLResponse(
               url: url,
               statusCode: 200,
               httpVersion: "HTTP/1.1",
               headerFields: [
                   "Content-Type": asset.mimeType,
                   "Content-Length": String(asset.data.count),
                   "Content-Security-Policy": policy,
               ]
           )
        {
            return response
        }
        return URLResponse(
            url: url,
            mimeType: asset.mimeType,
            expectedContentLength: asset.data.count,
            textEncodingName: nil
        )
    }
}

/// Filesystem work for a preview asset read. This type is not the URL-scheme
/// handler, so symlink resolution and file metadata stay off the main actor.
enum AssetFilesystemPreparation {
    struct ContainedAsset: Sendable {
        let asset: AssetURLPolicyResult
        let fileURL: URL
    }

    static func resolvedAssetURL(_ requestURL: URL, allowedRoot: URL) throws -> URL {
        let resolved = try AssetURLResolver(allowedRoot: allowedRoot).resolve(requestURL)
        // SVG is not a raster type. Containment already ran; structural validation
        // waits for the bytes, off the main actor.
        if !AssetURLPolicy.isSVG(resolved) {
            _ = try AssetURLPolicy.mimeType(for: resolved)
        }
        let maximum = AssetURLPolicy.maximumPreviewByteCount(for: resolved)
        if let fileSize = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > maximum
        {
            throw AssetURLPolicyError.fileTooLarge(
                actualBytes: Int64(fileSize),
                maxBytes: maximum
            )
        }
        return resolved
    }

    static func containedAsset(_ bytes: Data, fileURL: URL, root: URL) throws -> ContainedAsset {
        let contained = try AssetContainment.fileURL(fileURL, isContainedIn: root)
        let asset = try AssetURLPolicy.deliveredPreviewAsset(data: bytes, fileURL: contained)
        return ContainedAsset(asset: asset, fileURL: contained)
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
        case .reject:
            throw AssetURLPolicyError.unsupportedType(fileURL.pathExtension.lowercased())
        }
    }
}
