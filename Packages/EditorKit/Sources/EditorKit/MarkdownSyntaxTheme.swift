import AppKit

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

    public init(
        textColor: NSColor,
        mutedColor: NSColor,
        headingColor: NSColor,
        linkColor: NSColor,
        codeColor: NSColor,
        codeBackgroundColor: NSColor,
        frontmatterColor: NSColor,
        frontmatterBackgroundColor: NSColor,
        listMarkerColor: NSColor
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
            listMarkerColor: .systemOrange
        )
    }
}
