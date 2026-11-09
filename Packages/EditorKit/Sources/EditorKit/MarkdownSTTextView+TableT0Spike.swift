import AppKit
import MarkdownCore
import SyntaxKit

/// Non-user-facing table presentation hook (`docs/table-wysiwyg-gates.md` T0/T1). No App or
/// public presentation case reaches it. It parses the whole document for SyntaxKit table
/// regions, as the highlight pass will once the table gates wire it (T2+), and presents every
/// eligible one.
extension MarkdownSTTextView {
    private static var tableT0SpikeGeneration: UInt64 = 0

    @discardableResult
    func setWYSIWYGTableT0SpikeEnabled(_ isEnabled: Bool) -> Bool {
        guard isEnabled else {
            removeAllWYSIWYGTableRowPresentationMarkers()
            return true
        }
        guard let parser = try? MarkdownSyntaxParser(),
              setWYSIWYGZeroWidthFoldingEnabled(true),
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return false
        }

        Self.tableT0SpikeGeneration &+= 1
        let generation = Self.tableT0SpikeGeneration
        let availableWidth = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        let source = textStorage.string
        let regions = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            selection: NSRange(location: 0, length: 0),
            tableRegionsEnabled: true
        ).tableRegions
        let markers = regions.flatMap { region in
            let rowStart = region.sourceRange.location
            let paragraphStyle = rowStart < textStorage.length
                ? textStorage.attribute(.paragraphStyle, at: rowStart, effectiveRange: nil) as? NSParagraphStyle
                : nil
            return WYSIWYGTablePresentationPlanner.markers(
                for: region,
                in: textStorage,
                context: WYSIWYGTablePresentationPlanner.Context(
                    baseFont: font,
                    baseParagraphStyle: paragraphStyle ?? defaultParagraphStyle,
                    availableWidth: availableWidth,
                    generation: generation
                )
            ) ?? []
        }
        applyWYSIWYGTableRowPresentationMarkers(markers, generation: generation)
        return true
    }
}
