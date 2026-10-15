import Foundation
import PreviewKit

extension ExportHTMLNoticeMapper {
    /// The C2 warning sentence: which pages had to shrink past the 200-inch user-space
    /// limit and the smallest factor used. Names up to three pages, then "N others".
    static func shrunkPagesDetail(_ shrunkPages: [ExportPDFShrunkPage]) -> String {
        guard !shrunkPages.isEmpty else { return "" }
        let minimumScale = shrunkPages.map(\.scale).min() ?? 1
        let percent = Int((minimumScale * 100).rounded(.down))
        let percentText = percent == 0 ? "less than 1%" : "\(percent)%"
        let advice = " A line or table is very wide; adding line breaks or splitting " +
            "the table would make it readable."
        let limit = "to fit the PDF page limit (200 inches wide)."
        let named = shrunkPages.prefix(3).map { String($0.pageNumber) }
        switch shrunkPages.count {
        case 1:
            return " Page \(named[0]) was shrunk to \(percentText) \(limit)\(advice)"
        case 2:
            return " Pages \(named[0]) and \(named[1]) were shrunk (to as little as " +
                "\(percentText)) \(limit)\(advice)"
        case 3:
            return " Pages \(named[0]), \(named[1]), and \(named[2]) were shrunk " +
                "(to as little as \(percentText)) \(limit)\(advice)"
        default:
            let rest = shrunkPages.count - 3
            let others = rest == 1 ? "1 other" : "\(rest) others"
            return " Pages \(named[0]), \(named[1]), \(named[2]), and \(others) were shrunk " +
                "(to as little as \(percentText)) \(limit)\(advice)"
        }
    }
}
