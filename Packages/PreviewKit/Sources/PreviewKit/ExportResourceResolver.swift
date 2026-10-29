import Foundation

enum ExportResourceResolver {
    static let maximumDistinctDecodedRasterBytes: Int64 = 32 * 1024 * 1024
    static let exportImageSizeLimitReason = "Export image size limit"

    /// `normalizeDataURI` is a test seam for counting authored `data:` decodes.
    static func resolve(
        _ resources: [ExportResourceDescriptor],
        assetRoot: URL?,
        previewDirectory: URL?,
        normalizeDataURI: (String) -> ExportRasterDataURI.Normalized? = ExportRasterDataURI.normalized(from:)
    ) -> [ExportResourceOutcome] {
        let fonts = FontSource(previewDirectory: previewDirectory)
        var state = RasterBudget()
        return resources.map { resource in
            switch prepare(resource, fonts: fonts, assetRoot: assetRoot, normalize: normalizeDataURI, state: &state) {
            case let .resolved(outcome):
                return outcome
            case let .loadAsset(fileURL, identity):
                let loaded = Result { try AssetURLPolicy.loadAsset(at: fileURL) }
                return finishAsset(resource, identity: identity, loaded: loaded, state: &state)
            }
        }
    }

    /// iOS: local images come from the injected grant-scoped reader instead of a
    /// direct disk read. Containment, type, size, and the raster budget are unchanged.
    static func resolve(
        _ resources: [ExportResourceDescriptor],
        assetRoot: URL?,
        previewDirectory: URL?,
        loadAsset: @Sendable (URL) async throws -> AssetURLPolicyResult
    ) async -> [ExportResourceOutcome] {
        let fonts = FontSource(previewDirectory: previewDirectory)
        var state = RasterBudget()
        var outcomes: [ExportResourceOutcome] = []
        outcomes.reserveCapacity(resources.count)
        for resource in resources {
            switch prepare(
                resource,
                fonts: fonts,
                assetRoot: assetRoot,
                normalize: ExportRasterDataURI.normalized(from:),
                state: &state
            ) {
            case let .resolved(outcome):
                outcomes.append(outcome)
            case let .loadAsset(fileURL, identity):
                let loaded: Result<AssetURLPolicyResult, Error>
                do {
                    loaded = try await .success(loadAsset(fileURL))
                } catch {
                    loaded = .failure(error)
                }
                guard !Task.isCancelled else {
                    outcomes.append(.omit(resource, reason: "cancelled"))
                    continue
                }
                outcomes.append(autoreleasepool {
                    finishAsset(resource, identity: identity, loaded: loaded, state: &state)
                })
            }
        }
        return outcomes
    }

    private struct FontSource {
        let manifest: Set<String>
        let directory: URL?

        init(previewDirectory: URL?) {
            manifest = ExportFontManifest.woff2FileNames(in: previewDirectory)
            directory = previewDirectory?.appendingPathComponent("fonts", isDirectory: true)
        }
    }

    private enum Step {
        case resolved(ExportResourceOutcome)
        case loadAsset(fileURL: URL, identity: String)
    }

    private static func prepare(
        _ resource: ExportResourceDescriptor,
        fonts: FontSource,
        assetRoot: URL?,
        normalize: (String) -> ExportRasterDataURI.Normalized?,
        state: inout RasterBudget
    ) -> Step {
        guard !Task.isCancelled else {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "cancelled"))
        }
        switch resource.kind {
        case .font:
            return .resolved(resolveFont(resource, fontDirectory: fonts.directory, manifest: fonts.manifest))
        case .image:
            return prepareImage(resource, assetRoot: assetRoot, normalizeDataURI: normalize, state: &state)
        }
    }

    /// Distinct accepted rasters, keyed by resolved file path or normalized data URI.
    private struct RasterBudget {
        var decisionsByIdentity: [String: ImageDecision] = [:]
        var totalBytes: Int64 = 0
    }

    private enum ImageDecision {
        case accepted(firstResourceID: String)
        case omitted(reason: String)
    }

    private static func resolveFont(
        _ resource: ExportResourceDescriptor,
        fontDirectory: URL?,
        manifest: Set<String>
    ) -> ExportResourceOutcome {
        guard let fontDirectory,
              let fileName = ExportFontManifest.bundledFileName(from: resource.src),
              let dataURI = ExportFontManifest.dataURI(
                  fileName: fileName,
                  fontDirectory: fontDirectory,
                  manifest: manifest
              )
        else {
            return ExportResourceOutcome.omit(resource, reason: "font-unavailable")
        }
        return ExportResourceOutcome(
            resourceID: resource.resourceID,
            kind: .font,
            action: .embed,
            dataURI: dataURI
        )
    }

    private static func prepareImage(
        _ resource: ExportResourceDescriptor,
        assetRoot: URL?,
        normalizeDataURI: (String) -> ExportRasterDataURI.Normalized?,
        state: inout RasterBudget
    ) -> Step {
        let source = resource.src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "missing"))
        }
        if source.lowercased().hasPrefix("data:") {
            return .resolved(resolveDataImage(resource, source: source, normalize: normalizeDataURI, state: &state))
        }
        guard source.lowercased().hasPrefix("asset:") else {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "rejected-scheme"))
        }
        return prepareAssetImage(resource, source: source, assetRoot: assetRoot, state: state)
    }

    private static func resolveDataImage(
        _ resource: ExportResourceDescriptor,
        source: String,
        normalize: (String) -> ExportRasterDataURI.Normalized?,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        // A repeated authored image reuses the first decision before any base64 or ImageIO work.
        let sourceKey = ExportRasterDataURI.lookupKey(from: source)
        if let repeated = repeatedOutcome(resource, identity: sourceKey, state: state) {
            return repeated
        }
        guard let normalized = normalize(source) else {
            state.decisionsByIdentity[sourceKey] = .omitted(reason: "malformed-data")
            return ExportResourceOutcome.omit(resource, reason: "malformed-data")
        }
        let outcome = repeatedOutcome(resource, identity: normalized.uri, state: state) ?? accept(
            resource,
            identity: normalized.uri,
            byteCount: Int64(normalized.data.count),
            dataURI: normalized.uri,
            state: &state
        )
        state.decisionsByIdentity[sourceKey] = state.decisionsByIdentity[normalized.uri]
        return outcome
    }

    private static func prepareAssetImage(
        _ resource: ExportResourceDescriptor,
        source: String,
        assetRoot: URL?,
        state: RasterBudget
    ) -> Step {
        guard let assetRoot, let url = URL(string: source) else {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "unresolved"))
        }
        let fileURL: URL
        do {
            fileURL = try AssetURLResolver(allowedRoot: assetRoot).resolve(url)
        } catch AssetURLResolverError.pathEscapesRoot {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "escapes-root"))
        } catch {
            return .resolved(ExportResourceOutcome.omit(resource, reason: "unresolved"))
        }
        let identity = fileURL.path(percentEncoded: false)
        // A repeated reference reuses the first decision instead of re-reading the file.
        if let repeated = repeatedOutcome(resource, identity: identity, state: state) {
            return .resolved(repeated)
        }
        return .loadAsset(fileURL: fileURL, identity: identity)
    }

    private static func finishAsset(
        _ resource: ExportResourceDescriptor,
        identity: String,
        loaded: Result<AssetURLPolicyResult, Error>,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        let asset: AssetURLPolicyResult
        switch loaded {
        case let .success(value):
            asset = value
        case let .failure(error):
            let reason = omissionReason(for: error)
            state.decisionsByIdentity[identity] = .omitted(reason: reason)
            return ExportResourceOutcome.omit(resource, reason: reason)
        }
        guard ExportRasterSniffer.decodedMIMEType(of: asset.data) == asset.mimeType else {
            state.decisionsByIdentity[identity] = .omitted(reason: "unsupported")
            return ExportResourceOutcome.omit(resource, reason: "unsupported")
        }
        return accept(
            resource,
            identity: identity,
            byteCount: Int64(asset.data.count),
            dataURI: "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())",
            state: &state
        )
    }

    private static func omissionReason(for error: Error) -> String {
        switch error {
        case AssetURLResolverError.pathEscapesRoot, PreviewAssetReadFailure.outsideRoot:
            "escapes-root"
        case AssetURLPolicyError.fileTooLarge, PreviewAssetReadFailure.tooLarge:
            "too-large"
        default:
            "unresolved"
        }
    }

    private static func repeatedOutcome(
        _ resource: ExportResourceDescriptor,
        identity: String,
        state: RasterBudget
    ) -> ExportResourceOutcome? {
        switch state.decisionsByIdentity[identity] {
        case let .accepted(firstResourceID):
            // Protocol v8: name the first outcome instead of re-sending its data URI (R19).
            ExportResourceOutcome(
                resourceID: resource.resourceID,
                kind: .image,
                action: .embed,
                dataURIFrom: firstResourceID
            )
        case let .omitted(reason):
            ExportResourceOutcome.omit(resource, reason: reason)
        case nil:
            nil
        }
    }

    private static func accept(
        _ resource: ExportResourceDescriptor,
        identity: String,
        byteCount: Int64,
        dataURI: @autoclosure () -> String,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        let nextTotal = state.totalBytes.addingReportingOverflow(byteCount)
        guard !nextTotal.overflow,
              nextTotal.partialValue <= maximumDistinctDecodedRasterBytes
        else {
            // The total only grows, so a repeated reference can never fit later either.
            state.decisionsByIdentity[identity] = .omitted(reason: exportImageSizeLimitReason)
            return ExportResourceOutcome.omit(resource, reason: exportImageSizeLimitReason)
        }
        state.totalBytes = nextTotal.partialValue
        state.decisionsByIdentity[identity] = .accepted(firstResourceID: resource.resourceID)
        return ExportResourceOutcome(
            resourceID: resource.resourceID,
            kind: .image,
            action: .embed,
            dataURI: dataURI()
        )
    }
}
