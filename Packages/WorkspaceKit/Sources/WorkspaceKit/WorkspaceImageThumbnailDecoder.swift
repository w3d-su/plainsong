import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WorkspaceImageThumbnailDecodeResult: Equatable {
    let pngData: Data
    let width: Int
    let height: Int
    let decodedByteCost: Int
}

enum WorkspaceImageThumbnailDecoder {
    /// Downsamples with `CGImageSource` thumbnailing. Never materializes a full-size bitmap of a
    /// huge photo; animated GIF yields only the first frame (`index: 0`).
    static func decodePNGThumbnail(
        from fileURL: URL,
        maxPixelSize: Int
    ) throws -> WorkspaceImageThumbnailDecodeResult {
        precondition(maxPixelSize > 0, "maxPixelSize must be positive")

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw WorkspaceImageThumbnailFailure.unreadableFile
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw WorkspaceImageThumbnailFailure.emptyImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        // Index 0 is the first (and only) frame for stills and the first frame for animated GIF.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WorkspaceImageThumbnailFailure.decodeFailed
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw WorkspaceImageThumbnailFailure.emptyImage
        }

        let pngData = try encodePNG(image)
        return WorkspaceImageThumbnailDecodeResult(
            pngData: pngData,
            width: width,
            height: height,
            decodedByteCost: width * height * 4
        )
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WorkspaceImageThumbnailFailure.decodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WorkspaceImageThumbnailFailure.decodeFailed
        }
        return data as Data
    }
}
