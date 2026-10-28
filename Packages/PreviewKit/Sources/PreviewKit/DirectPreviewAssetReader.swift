import Foundation

/// Mac direct-read adapter. It does not choose the allowlist: `AssetURLPolicy.loadAsset`
/// still checks metadata size, then the byte count of what was read.
struct DirectPreviewAssetReader: PreviewAssetReading {
    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        try Task.checkCancellation()
        let url = request.resolvedURL
        if AssetURLPolicy.isSVG(url) {
            let data = try Self.svgBytes(at: url, maximumByteCount: request.maximumByteCount)
            try Task.checkCancellation()
            return PreviewAssetReadResult(
                requestID: request.requestID,
                coordinatedURL: url,
                bytes: data,
                access: request.access
            )
        }
        let asset: AssetURLPolicyResult
        do {
            asset = try AssetURLPolicy.loadAsset(at: url)
        } catch let error as AssetURLPolicyError {
            throw Self.failure(for: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PreviewAssetReadFailure {
            throw failure
        } catch {
            throw PreviewAssetReadFailure.providerFailed
        }
        try Task.checkCancellation()
        guard asset.data.count <= request.maximumByteCount else {
            throw PreviewAssetReadFailure.tooLarge
        }
        return PreviewAssetReadResult(
            requestID: request.requestID,
            coordinatedURL: url,
            bytes: asset.data,
            access: request.access
        )
    }

    /// SVG stays out of `loadAsset` so export remains raster-only. The scheme handler validates the bytes.
    private static func svgBytes(at url: URL, maximumByteCount: Int) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw PreviewAssetReadFailure.providerFailed
            }
            if fileSize > maximumByteCount {
                throw PreviewAssetReadFailure.tooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumByteCount else {
                throw PreviewAssetReadFailure.tooLarge
            }
            return data
        } catch let failure as PreviewAssetReadFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PreviewAssetReadFailure.providerFailed
        }
    }

    private static func failure(for error: AssetURLPolicyError) -> PreviewAssetReadFailure {
        switch error {
        case .unsupportedType:
            .unsupportedType
        case .fileTooLarge:
            .tooLarge
        case .missingFileSize:
            .providerFailed
        }
    }
}
