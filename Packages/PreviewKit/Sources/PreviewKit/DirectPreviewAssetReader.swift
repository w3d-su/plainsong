import Foundation

/// Mac direct-read adapter. It does not choose the allowlist: `AssetURLPolicy.loadAsset`
/// still checks metadata size, then the byte count of what was read.
struct DirectPreviewAssetReader: PreviewAssetReading {
    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        try Task.checkCancellation()
        let url = request.resolvedURL
        let asset: AssetURLPolicyResult
        do {
            asset = try AssetURLPolicy.loadAsset(at: url)
        } catch let error as AssetURLPolicyError {
            throw Self.failure(for: error)
        } catch is CancellationError {
            throw CancellationError()
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
