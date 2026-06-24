import AppKit

public enum MarkdownEditorTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case graphite

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .standard:
            "Plainsong"
        case .graphite:
            "Graphite"
        }
    }
}

/// Source editor colors used by the pragmatic M1 highlighter.
public struct MarkdownSyntaxTheme {
    public var textColor: NSColor
    public var mutedColor: NSColor
    public var headingColor: NSColor
    public var linkColor: NSColor
    public var codeColor: NSColor
    public var codeBackgroundColor: NSColor
    public var frontmatterColor: NSColor
    public var frontmatterBackgroundColor: NSColor
    public var listMarkerColor: NSColor
    public var tsxKeywordColor: NSColor
    public var tsxStringColor: NSColor
    public var tsxTagColor: NSColor
    public var tsxAttributeColor: NSColor
    public var tsxPunctuationColor: NSColor

    public init(
        textColor: NSColor,
        mutedColor: NSColor,
        headingColor: NSColor,
        linkColor: NSColor,
        codeColor: NSColor,
        codeBackgroundColor: NSColor,
        frontmatterColor: NSColor,
        frontmatterBackgroundColor: NSColor,
        listMarkerColor: NSColor,
        tsxKeywordColor: NSColor,
        tsxStringColor: NSColor,
        tsxTagColor: NSColor,
        tsxAttributeColor: NSColor,
        tsxPunctuationColor: NSColor
    ) {
        self.textColor = textColor
        self.mutedColor = mutedColor
        self.headingColor = headingColor
        self.linkColor = linkColor
        self.codeColor = codeColor
        self.codeBackgroundColor = codeBackgroundColor
        self.frontmatterColor = frontmatterColor
        self.frontmatterBackgroundColor = frontmatterBackgroundColor
        self.listMarkerColor = listMarkerColor
        self.tsxKeywordColor = tsxKeywordColor
        self.tsxStringColor = tsxStringColor
        self.tsxTagColor = tsxTagColor
        self.tsxAttributeColor = tsxAttributeColor
        self.tsxPunctuationColor = tsxPunctuationColor
    }

    public static var standard: MarkdownSyntaxTheme {
        MarkdownSyntaxTheme(
            textColor: .labelColor,
            mutedColor: .secondaryLabelColor,
            headingColor: .labelColor,
            linkColor: .linkColor,
            codeColor: .systemPurple,
            codeBackgroundColor: .controlBackgroundColor.withAlphaComponent(0.8),
            frontmatterColor: .systemTeal,
            frontmatterBackgroundColor: .controlBackgroundColor.withAlphaComponent(0.6),
            listMarkerColor: .systemOrange,
            tsxKeywordColor: .systemPink,
            tsxStringColor: .systemGreen,
            tsxTagColor: .systemBlue,
            tsxAttributeColor: .systemTeal,
            tsxPunctuationColor: .secondaryLabelColor
        )
    }

    public static func builtIn(_ theme: MarkdownEditorTheme) -> MarkdownSyntaxTheme {
        switch theme {
        case .standard:
            standard
        case .graphite:
            graphite
        }
    }

    public static var graphite: MarkdownSyntaxTheme {
        MarkdownSyntaxTheme(
            textColor: .labelColor,
            mutedColor: .tertiaryLabelColor,
            headingColor: .controlAccentColor,
            linkColor: .linkColor,
            codeColor: .systemIndigo,
            codeBackgroundColor: .controlBackgroundColor.withAlphaComponent(0.7),
            frontmatterColor: .systemBrown,
            frontmatterBackgroundColor: .controlBackgroundColor.withAlphaComponent(0.55),
            listMarkerColor: .systemGray,
            tsxKeywordColor: .systemPurple,
            tsxStringColor: .systemGreen,
            tsxTagColor: .systemBlue,
            tsxAttributeColor: .systemTeal,
            tsxPunctuationColor: .secondaryLabelColor
        )
    }
}
