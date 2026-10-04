import Darwin
import Foundation

extension PreviewHTMLExportResult {
    /// The opening tag the static serializer writes for each image that D3 replaced by an inert
    /// placeholder (`placeholderElement` in `preview-src/src/export-html-assets.ts`: class, then
    /// `role="img"`, then the alt-text label).
    ///
    /// Sanitized document content cannot produce this tag. Markdown drops raw HTML, and the MDX
    /// sanitizer drops `role` (`mdxSanitizeSchema`). In text and attribute values, `<` and `"`
    /// are escaped, so the literal tag never appears as data.
    static let omittedImagePlaceholderTag = #"<span class="export-image-placeholder" role="img""#

    /// How many images the D3 asset policy replaced by inert placeholders in a ready export.
    ///
    /// This counts both kinds of omission:
    /// - outcomes PreviewKit decided (containment, type, size, missing or unreadable, remote);
    /// - outcomes the serializer decided (aggregate limits, or an image WebKit could not decode).
    ///
    /// It is derived from the returned HTML alone and needs no bridge change. A failed export
    /// has no document, so it reports `0`.
    public var omittedImageCount: Int {
        guard case let .ready(html, _, _) = self else { return 0 }
        return Self.occurrences(of: Self.omittedImagePlaceholderTag, in: html)
    }

    static func occurrences(of marker: String, in text: String) -> Int {
        var text = text
        let needle = Array(marker.utf8)
        guard !needle.isEmpty else { return 0 }
        return text.withUTF8 { haystack in
            guard let base = haystack.baseAddress, haystack.count >= needle.count else { return 0 }
            return needle.withUnsafeBufferPointer { needleBuffer in
                var count = 0
                var offset = 0
                while haystack.count - offset >= needleBuffer.count,
                      let found = memmem(
                          base + offset,
                          haystack.count - offset,
                          needleBuffer.baseAddress,
                          needleBuffer.count
                      )
                {
                    count += 1
                    offset = UnsafeRawPointer(found) - UnsafeRawPointer(base) + needleBuffer.count
                }
                return count
            }
        }
    }
}
