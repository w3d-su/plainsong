import Foundation

/// Semantic kinds shared by the existing Mac parser and the future iOS provider.
/// Ranges are absolute UTF-16 offsets in the complete source, never UTF-8 bytes.
public struct MarkdownSyntaxToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case frontmatter
        case frontmatterKey
        case headingMarker
        case headingText(level: Int)
        case listMarker
        case codeBlock
        case codeFenceMarker
        case codeFenceInfo
        case inlineCode
        case strong
        case emphasis
        case linkText
        case linkDestination
        case quoteMarker
        case tableHeader
        case tableDelimiter
        case tablePipe
        case mdxSource
        case tsxKeyword
        case tsxString
        case tsxTag
        case tsxAttribute
        case tsxPunctuation
    }

    public let kind: Kind
    public let range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}
