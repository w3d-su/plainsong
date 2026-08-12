import AppKit

extension EditorFindMatchHighlight {
    typealias CoveredBackground = (range: NSRange, color: NSColor)

    static func mergedSearchBounds(_ ranges: [NSRange], storageLength: Int) -> [NSRange] {
        let candidates = ranges
            .map { $0.clamped(toLength: storageLength) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for candidate in candidates {
            if let last = merged.last,
               last.location + last.length >= candidate.location
            {
                merged[merged.count - 1] = NSUnionRange(last, candidate)
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    static func decoratedRanges(
        in textStorage: NSTextStorage,
        searching bounds: [NSRange]
    ) -> [NSRange] {
        var decorated: [NSRange] = []
        for bound in bounds {
            textStorage.enumerateAttribute(
                EditorFindMatchHighlightMarker.attribute,
                in: bound
            ) { value, range, _ in
                guard value is EditorFindMatchHighlightMarker else { return }
                decorated.append(range)
            }
        }
        return decorated
    }

    static func coveredBackgrounds(
        in textStorage: NSTextStorage,
        ranges: [NSRange]
    ) -> [CoveredBackground] {
        var covered: [CoveredBackground] = []
        for range in ranges {
            textStorage.enumerateAttribute(
                EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
                in: range
            ) { value, range, _ in
                guard let color = value as? NSColor else { return }
                covered.append((range, color))
            }
        }
        return covered
    }

    static func removeDecoration(
        in textStorage: NSTextStorage,
        ranges: [NSRange],
        searchBounds: [NSRange]
    ) {
        for range in ranges {
            textStorage.removeAttribute(EditorFindMatchHighlightMarker.attribute, range: range)
            textStorage.removeAttribute(.backgroundColor, range: range)
        }
        // Also remove any fragment that an attribute-inheritance edge left without a marker.
        for bound in searchBounds {
            textStorage.removeAttribute(
                EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
                range: bound
            )
        }
    }

    static func restore(_ backgrounds: [CoveredBackground], in textStorage: NSTextStorage) {
        for covered in backgrounds {
            let clamped = covered.range.clamped(toLength: textStorage.length)
            guard clamped.length > 0 else { continue }
            textStorage.addAttribute(.backgroundColor, value: covered.color, range: clamped)
        }
    }
}
