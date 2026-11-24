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
        guard let image = uprightImage(from: source) else { return nil }
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

    /// A camera HEIC stores the sensor's pixels plus an EXIF orientation, and the PNG
    /// written here carries no orientation, so the rotation is applied to the pixels.
    private func uprightImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard orientation != 1, max(width, height) > 0 else {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            return CGImageSourceCreateImageAtIndex(source, 0, options)
        }
        // The thumbnail call is ImageIO's transform-applying decode; the size limit is
        // the image's own longer side, so nothing is scaled.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
