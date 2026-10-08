import Foundation
import SyntaxKit

enum IOSSyntaxAttribute {
    static let key = NSAttributedString.Key("app.plainsong.ios.syntax")

    static func token(for kind: MarkdownSyntaxToken.Kind) -> String {
        switch kind {
        case let .headingText(level):
            "headingText:\(level)"
        default:
            String(describing: kind)
        }
    }
}
