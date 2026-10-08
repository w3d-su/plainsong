import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol IOSImageRasterTranscoding: Sendable {
    /// Decode a HEIC/HEIF payload and return newly encoded PNG bytes.
    func pngData(fromHEIC data: Data) -> Data?
}

/// ImageIO writes a PNG container. Renaming a HEIC file is not conversion.
struct IOSImageIORasterTranscoder: IOSImageRasterTranscoding {
    func pngData(fromHEIC data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
