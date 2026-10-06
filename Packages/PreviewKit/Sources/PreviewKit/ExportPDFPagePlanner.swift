import CoreGraphics
import Foundation

/// One operation-fixed page height for Export as PDF… (`docs/export-gates.md` D4).
///
/// The search matches the E0 spike: integer candidates from 14,400 pt downward, and a
/// candidate is safe only when no page boundary crosses a block. Callers measure blocks
/// after export layout and, when needed, after the single uniform scale.
public enum ExportPDFPagePlanner {
    public static let maximumSide: CGFloat = 14400

    public struct Block: Equatable, Sendable {
        public let minY: CGFloat
        public let maxY: CGFloat

        public init(minY: CGFloat, maxY: CGFloat) {
            self.minY = minY
            self.maxY = maxY
        }

        public var height: CGFloat {
            maxY - minY
        }
    }

    /// 1 until the contained overflow width exceeds 14,400 pt, then the single factor that
    /// brings that width down to the maximum. Applied to the whole capture, not per element.
    public static func uniformScale(containedWidth: CGFloat) -> CGFloat {
        guard containedWidth > maximumSide, containedWidth.isFinite else { return 1 }
        return maximumSide / containedWidth
    }

    /// `nil` when no single height in `minimumHeight...14400` misses every block.
    public static func fixedHeight(
        contentMinY: CGFloat,
        contentMaxY: CGFloat,
        blocks: [Block],
        minimumHeight: Int = 6000,
        boundaryClearance: CGFloat = 0.5
    ) -> CGFloat? {
        for candidate in stride(from: Int(maximumSide), through: minimumHeight, by: -1) {
            let pageHeight = CGFloat(candidate)
            var boundary = contentMinY + pageHeight
            var isSafe = true
            while boundary < contentMaxY - 0.5 {
                if blocks.contains(where: {
                    boundary >= $0.minY - boundaryClearance && boundary <= $0.maxY + boundaryClearance
                }) {
                    isSafe = false
                    break
                }
                boundary += pageHeight
            }
            if isSafe {
                return pageHeight
            }
        }
        return nil
    }
}
