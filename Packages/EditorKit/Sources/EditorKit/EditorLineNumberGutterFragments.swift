import AppKit
import STTextView

/// Reads the laid-out TextKit fragments that a gutter rect shows.
enum EditorLineNumberGutterFragments {
    /// Fragments intersecting `minY...maxY` (text view coordinates), visiting only the
    /// TextKit viewport: past its end TextKit would create elements the cache trimmer
    /// has released. Fragments without layout are skipped; their layout redraws the gutter.
    @MainActor
    static func visible(
        in textView: STTextView,
        minY: CGFloat,
        maxY: CGFloat,
        limit: Int
    ) -> (fragments: [EditorLineNumberGutterLayout.Fragment], visited: Int) {
        let layoutManager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        let documentRange = contentManager.documentRange
        if documentRange.isEmpty {
            let fragment = emptyDocumentFragment(
                in: layoutManager,
                defaultParagraphStyle: textView.defaultParagraphStyle
            )
            return (fragment.map { [$0] } ?? [], 0)
        }
        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return ([], 0)
        }

        var fragments: [EditorLineNumberGutterLayout.Fragment] = []
        var visited = 0
        layoutManager.enumerateTextLayoutFragments(from: viewportRange.location) { fragment in
            visited += 1
            guard visited <= limit,
                  fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending
            else {
                return false
            }
            let frame = fragment.layoutFragmentFrame
            if frame.minY > maxY {
                return false
            }
            guard frame.maxY >= minY, fragment.state == .layoutAvailable else {
                return true
            }
            let location = contentManager.offset(from: documentRange.location, to: fragment.rangeInElement.location)
            guard location != NSNotFound else { return true }
            fragments.append(self.fragment(
                fragment,
                at: location,
                defaultParagraphStyle: textView.defaultParagraphStyle
            ))
            return true
        }
        return (fragments, visited)
    }

    @MainActor
    static func fragment(
        _ fragment: NSTextLayoutFragment,
        at location: Int,
        defaultParagraphStyle: NSParagraphStyle?
    ) -> EditorLineNumberGutterLayout.Fragment {
        let origin = fragment.layoutFragmentFrame.origin
        var result = EditorLineNumberGutterLayout.Fragment(location: location)
        for lineFragment in fragment.textLineFragments {
            let bounds = lineFragment.typographicBounds
            let line = EditorLineNumberGutterLayout.Line(
                frame: bounds.offsetBy(dx: origin.x, dy: origin.y),
                baseline: origin.y + bounds.minY + lineFragment.glyphOrigin.y
                    + paintedBaselineShift(of: lineFragment, defaultParagraphStyle: defaultParagraphStyle)
            )
            if lineFragment.isExtraLineFragment {
                result.extraLine = line
            } else {
                if result.firstLine == nil {
                    result.firstLine = line
                }
                result.bodyFrame = result.bodyFrame?.union(line.frame) ?? line.frame
            }
        }
        return result
    }

    /// STTextView paints each line fragment raised by half of the height that its line
    /// height multiple adds (`STTextLayoutFragment.draw`), so the painted baseline sits
    /// above TextKit's. Numbers follow the painted text: the same paragraph-style rule
    /// (the paragraph's own style, else the text view's default) and the same offset.
    nonisolated static func paintedBaselineShift(
        lineHeight: CGFloat,
        paragraphStyle: NSParagraphStyle?
    ) -> CGFloat {
        let multiple = paragraphStyle?.lineHeightMultiple ?? 0
        guard abs(multiple) > .ulpOfOne else { return 0 }
        return -(lineHeight * (multiple - 1) / 2)
    }

    private static func paintedBaselineShift(
        of lineFragment: NSTextLineFragment,
        defaultParagraphStyle: NSParagraphStyle?
    ) -> CGFloat {
        let ownStyle = lineFragment.characterRange.length > 0
            ? lineFragment.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil
        return paintedBaselineShift(
            lineHeight: lineFragment.typographicBounds.height,
            paragraphStyle: ownStyle ?? defaultParagraphStyle
        )
    }

    /// An empty document has no fragments; number the line the caret stands on.
    @MainActor
    private static func emptyDocumentFragment(
        in layoutManager: NSTextLayoutManager,
        defaultParagraphStyle: NSParagraphStyle?
    ) -> EditorLineNumberGutterLayout.Fragment? {
        var line: EditorLineNumberGutterLayout.Line?
        layoutManager.enumerateTextSegments(
            in: NSTextRange(location: layoutManager.documentRange.location),
            type: .standard,
            options: [.upstreamAffinity]
        ) { _, frame, baselinePosition, _ in
            let shift = paintedBaselineShift(lineHeight: frame.height, paragraphStyle: defaultParagraphStyle)
            line = EditorLineNumberGutterLayout.Line(frame: frame, baseline: frame.minY + baselinePosition + shift)
            return false
        }
        guard let line else { return nil }
        return EditorLineNumberGutterLayout.Fragment(location: 0, firstLine: line, bodyFrame: line.frame)
    }
}
