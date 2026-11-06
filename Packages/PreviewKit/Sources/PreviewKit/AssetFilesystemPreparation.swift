import Foundation

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

    /// `requestedURL` chose the byte cap; `fileURL` is what the reader actually read and
    /// chooses the validator. They must agree on being SVG, or neither decision holds.
    static func containedAsset(_ bytes: Data, fileURL: URL, requestedURL: URL, root: URL) throws -> ContainedAsset {
        guard AssetURLPolicy.isSVG(fileURL) == AssetURLPolicy.isSVG(requestedURL) else {
            throw AssetURLPolicyError.kindChangedDuringRead
        }
        let contained = try AssetContainment.fileURL(fileURL, isContainedIn: root)
        let asset = try AssetURLPolicy.deliveredPreviewAsset(data: bytes, fileURL: contained)
        return ContainedAsset(asset: asset, fileURL: contained)
    }
}
