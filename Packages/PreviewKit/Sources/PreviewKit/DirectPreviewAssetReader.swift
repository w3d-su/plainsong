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

    /// SVG stays out of `loadAsset` so export remains raster-only. The scheme handler
    /// validates the bytes. The open never blocks (`O_NONBLOCK`, so a FIFO named `x.svg`
    /// cannot stall the read), the descriptor must be a regular file, and at most one
    /// byte past the cap is read, so a file that grows after the size check stays bounded.
    static func svgBytes(at url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw PreviewAssetReadFailure.providerFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw PreviewAssetReadFailure.providerFailed }
        guard status.st_mode & S_IFMT == S_IFREG else { throw PreviewAssetReadFailure.unsupportedType }
        guard status.st_size <= off_t(maximumByteCount) else { throw PreviewAssetReadFailure.tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        } catch {
            throw PreviewAssetReadFailure.providerFailed
        }
        guard data.count <= maximumByteCount else { throw PreviewAssetReadFailure.tooLarge }
        return data
    }

    private static func failure(for error: AssetURLPolicyError) -> PreviewAssetReadFailure {
        switch error {
        case .unsupportedType, .rejectedSVG, .kindChangedDuringRead:
            .unsupportedType
        case .fileTooLarge:
            .tooLarge
        case .missingFileSize:
            .providerFailed
        }
    }
}
