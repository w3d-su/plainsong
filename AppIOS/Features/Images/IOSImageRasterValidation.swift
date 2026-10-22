import Foundation
import ImageIO

/// Signatures select the policy; successful immediate decoding proves this is an image payload.
enum IOSImageRasterValidation {
    static func isCompleteImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete
        else { return false }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return false }
        return image.width > 0 && image.height > 0
    }
}
