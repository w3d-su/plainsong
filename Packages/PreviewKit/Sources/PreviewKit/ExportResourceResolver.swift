import Foundation

enum ExportResourceResolver {
    static let maximumDistinctDecodedRasterBytes: Int64 = 32 * 1024 * 1024
    static let exportImageSizeLimitReason = "Export image size limit"

    static func resolve(
        _ resources: [ExportResourceDescriptor],
        assetRoot: URL?,
        previewDirectory: URL?
    ) -> [ExportResourceOutcome] {
        let manifest = ExportFontManifest.woff2FileNames(in: previewDirectory)
        let fontDirectory = previewDirectory?.appendingPathComponent("fonts", isDirectory: true)
        var state = RasterBudget()
        return resources.map { resource in
            guard !Task.isCancelled else {
                return ExportResourceOutcome.omit(resource, reason: "cancelled")
            }
            switch resource.kind {
            case .font:
                return resolveFont(resource, fontDirectory: fontDirectory, manifest: manifest)
            case .image:
                return resolveImage(resource, assetRoot: assetRoot, state: &state)
            }
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

    private static func resolveImage(
        _ resource: ExportResourceDescriptor,
        assetRoot: URL?,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        let source = resource.src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            return ExportResourceOutcome.omit(resource, reason: "missing")
        }
        if source.lowercased().hasPrefix("data:") {
            return resolveDataImage(resource, source: source, state: &state)
        }
        guard source.lowercased().hasPrefix("asset:") else {
            return ExportResourceOutcome.omit(resource, reason: "rejected-scheme")
        }
        return resolveAssetImage(resource, source: source, assetRoot: assetRoot, state: &state)
    }

    private static func resolveDataImage(
        _ resource: ExportResourceDescriptor,
        source: String,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        guard let normalized = ExportRasterDataURI.normalized(from: source) else {
            return ExportResourceOutcome.omit(resource, reason: "malformed-data")
        }
        if let repeated = repeatedOutcome(resource, identity: normalized.uri, state: state) {
            return repeated
        }
        return accept(
            resource,
            identity: normalized.uri,
            byteCount: Int64(normalized.data.count),
            dataURI: normalized.uri,
            state: &state
        )
    }

    private static func resolveAssetImage(
        _ resource: ExportResourceDescriptor,
        source: String,
        assetRoot: URL?,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        guard let assetRoot, let url = URL(string: source) else {
            return ExportResourceOutcome.omit(resource, reason: "unresolved")
        }
        do {
            let fileURL = try AssetURLResolver(allowedRoot: assetRoot).resolve(url)
            let identity = fileURL.path(percentEncoded: false)
            // A repeated reference reuses the first decision instead of re-reading the file.
            if let repeated = repeatedOutcome(resource, identity: identity, state: state) {
                return repeated
            }
            let asset = try AssetURLPolicy.loadAsset(at: fileURL)
            guard ExportRasterSniffer.decodedMIMEType(of: asset.data) == asset.mimeType else {
                state.decisionsByIdentity[identity] = .omitted(reason: "unsupported")
                return ExportResourceOutcome.omit(resource, reason: "unsupported")
            }
            let dataURI = "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())"
            return accept(
                resource,
                identity: identity,
                byteCount: Int64(asset.data.count),
                dataURI: dataURI,
                state: &state
            )
        } catch AssetURLResolverError.pathEscapesRoot {
            return ExportResourceOutcome.omit(resource, reason: "escapes-root")
        } catch AssetURLPolicyError.fileTooLarge {
            return ExportResourceOutcome.omit(resource, reason: "too-large")
        } catch {
            return ExportResourceOutcome.omit(resource, reason: "unresolved")
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
        dataURI: String,
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
            dataURI: dataURI
        )
    }
}
