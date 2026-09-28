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

    private struct RasterBudget {
        var dataURIsByIdentity: [String: String] = [:]
        var totalBytes: Int64 = 0
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
            let asset = try AssetURLPolicy.loadAsset(at: fileURL)
            guard ExportRasterSniffer.mimeType(of: asset.data) == asset.mimeType else {
                return ExportResourceOutcome.omit(resource, reason: "unsupported")
            }
            let dataURI = "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())"
            return accept(
                resource,
                identity: fileURL.path(percentEncoded: false),
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

    private static func accept(
        _ resource: ExportResourceDescriptor,
        identity: String,
        byteCount: Int64,
        dataURI: String,
        state: inout RasterBudget
    ) -> ExportResourceOutcome {
        if state.dataURIsByIdentity[identity] == nil {
            let nextTotal = state.totalBytes.addingReportingOverflow(byteCount)
            guard !nextTotal.overflow,
                  nextTotal.partialValue <= maximumDistinctDecodedRasterBytes
            else {
                return ExportResourceOutcome.omit(resource, reason: exportImageSizeLimitReason)
            }
            state.totalBytes = nextTotal.partialValue
            state.dataURIsByIdentity[identity] = dataURI
        }
        return ExportResourceOutcome(
            resourceID: resource.resourceID,
            kind: .image,
            action: .embed,
            dataURI: state.dataURIsByIdentity[identity]
        )
    }
}
