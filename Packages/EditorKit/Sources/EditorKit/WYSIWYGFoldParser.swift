import Foundation
import SyntaxKit

/// Mac compatibility name. Fold presentation attributes stay in EditorKit.
typealias WYSIWYGFoldParser = SyntaxKit.WYSIWYGFoldParser

extension NSRange {
    func offset(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }

    func intersects(_ other: NSRange) -> Bool {
        NSIntersectionRange(self, other).length > 0
    }
}
