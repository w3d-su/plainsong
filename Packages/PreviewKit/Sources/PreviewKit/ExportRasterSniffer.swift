import Foundation
import ImageIO
import MarkdownCore
import UniformTypeIdentifiers

enum ExportRasterSniffer {
    static let maximumRasterBytes = MarkdownImageAssetPolicy.maximumFileSizeBytes

    /// Returns an allowlisted raster MIME type only after ImageIO actually decodes the
    /// first frame. `CGImageSourceGetType` alone reads the signature, so a header-only or
    /// corrupt-body PNG would pass it. A small thumbnail forces the full decode while
    /// bounding the decoded bitmap, which a full-size image would not.
    static func decodedMIMEType(of data: Data) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source) as String?,
              let mimeType = allowlistedMIMEType(identifier),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            return nil
        }
        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeProofMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions),
              decoded.width > 0,
              decoded.height > 0
        else {
            return nil
        }
        return mimeType
    }

    private static let decodeProofMaximumPixelSize = 16

    private static func allowlistedMIMEType(_ identifier: String) -> String? {
        switch identifier {
        case UTType.png.identifier:
            "image/png"
        case UTType.jpeg.identifier:
            "image/jpeg"
        case UTType.gif.identifier:
            "image/gif"
        case UTType.webP.identifier:
            "image/webp"
        default:
            nil
        }
    }
}

enum ExportRasterDataURI {
    struct Normalized: Equatable {
        let mimeType: String
        let data: Data
        let uri: String
    }

    static func normalized(from source: String) -> Normalized? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ","),
              trimmed[..<comma].lowercased().hasPrefix("data:")
        else {
            return nil
        }

        let metadata = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5) ..< comma]
        let payload = trimmed[trimmed.index(after: comma)...]
        guard let mimeType = declaredImageMIME(metadata),
              payload.count <= maximumBase64Characters
        else {
            return nil
        }

        guard let data = Data(base64Encoded: String(payload)) else {
            return nil
        }
        guard data.count <= ExportRasterSniffer.maximumRasterBytes,
              ExportRasterSniffer.decodedMIMEType(of: data) == mimeType
        else {
            return nil
        }

        let uri = "data:\(mimeType);base64,\(data.base64EncodedString())"
        return Normalized(mimeType: mimeType, data: data, uri: uri)
    }

    /// A cheap repeat key built from exactly the inputs `normalized(from:)` reads: the
    /// `data:` prefix, the trimmed and lowercased metadata parameters, and the untouched
    /// payload. Equal keys therefore normalize identically, so a repeat is answered before
    /// any base64 or ImageIO work; differently encoded payloads still meet at `uri`.
    static func lookupKey(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ","),
              trimmed[..<comma].lowercased().hasPrefix("data:")
        else {
            return trimmed
        }
        let metadata = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5) ..< comma]
        let parameters = metadata.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return "data:\(parameters.joined(separator: ";"))\(trimmed[comma...])"
    }

    private static var maximumBase64Characters: Int {
        ((Int(ExportRasterSniffer.maximumRasterBytes) + 2) / 3) * 4 + 4
    }

    private static func declaredImageMIME(_ metadata: Substring) -> String? {
        let parts = metadata.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard parts.count == 2, parts[1] == "base64" else {
            return nil
        }
        let mimeType = parts[0]
        guard MarkdownImageAssetPolicy.mimeTypesByPathExtension.values.contains(mimeType) else {
            return nil
        }
        return mimeType
    }
}
