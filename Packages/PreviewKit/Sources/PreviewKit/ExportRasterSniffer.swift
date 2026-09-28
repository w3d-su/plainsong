import Foundation
import ImageIO
import MarkdownCore
import UniformTypeIdentifiers

enum ExportRasterSniffer {
    static let maximumRasterBytes = MarkdownImageAssetPolicy.maximumFileSizeBytes

    static func mimeType(of data: Data) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source) as String?
        else {
            return nil
        }

        switch identifier {
        case UTType.png.identifier:
            return "image/png"
        case UTType.jpeg.identifier:
            return "image/jpeg"
        case UTType.gif.identifier:
            return "image/gif"
        case UTType.webP.identifier:
            return "image/webp"
        default:
            return nil
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
              ExportRasterSniffer.mimeType(of: data) == mimeType
        else {
            return nil
        }

        let uri = "data:\(mimeType);base64,\(data.base64EncodedString())"
        return Normalized(mimeType: mimeType, data: data, uri: uri)
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
