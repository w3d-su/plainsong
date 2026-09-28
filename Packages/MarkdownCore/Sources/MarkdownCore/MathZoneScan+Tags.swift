import Foundation

/// HTML/JSX tag and container handling for the `MathZones` scanner.
extension MathZones {
    // MARK: - HTML / JSX containers

    /// `<Name …>`, `</Name>`, `<!-- -->`, `<!doctype>` — a line that starts with
    /// a tag. Used by the display-insert paragraph check.
    func tagToken(in line: MarkdownLine) -> MathTagToken? {
        let storage = line.text as NSString
        var index = 0
        while index < storage.length, storage.character(at: index) == 32 || storage.character(at: index) == 9 {
            index += 1
        }
        guard index <= 3, index < storage.length, storage.character(at: index) == 60 else { return nil }
        guard let head = tagHead(at: index, in: storage) else { return nil }
        guard head.isContainerEligible || head.isStandalone else { return nil }
        return MathTagToken(name: head.name, isClosing: head.isClosing, isSelfContained: false)
    }

    /// The tag head when the stripped line's first non-whitespace char is `<`.
    func lineStartTagHead(in line: MarkdownLine, context ctx: MathLineContext) -> MathTagHead? {
        let storage = line.text as NSString
        let index = ctx.contentIndex
        guard index < storage.length, storage.character(at: index) == 60,
              ctx.contentIndent <= 3
        else { return nil }
        return tagHead(at: index, in: storage)
    }

    /// `.md` HTML block kinds (CommonMark): comments/declarations end on a
    /// marker, `script`/`pre`/`style`/`textarea` on their close tag, the block
    /// name list and complete-tags-alone end at a blank line.
    func htmlBlockEnd(
        for head: MathTagHead, in line: MarkdownLine, context ctx: MathLineContext,
        canInterrupt: Bool
    ) -> MathHtmlBlockEnd? {
        let storage = line.text as NSString
        let index = ctx.contentIndex
        if head.isStandalone {
            return standaloneBlockEnd(in: storage, at: index)
        }
        if head.isClosing {
            return canInterrupt && tagCompletesOnLine(in: storage, at: index) ? .blank : nil
        }
        if Self.rawTextTags.contains(head.name) {
            return .marker("</" + head.name)
        }
        if Self.blockTags.contains(head.name) {
            return .blank
        }
        return canInterrupt && tagCompletesOnLine(in: storage, at: index) ? .blank : nil
    }

    func standaloneBlockEnd(in storage: NSString, at index: Int) -> MathHtmlBlockEnd {
        if index + 3 < storage.length,
           storage.character(at: index + 1) == 33,
           storage.character(at: index + 2) == 45,
           storage.character(at: index + 3) == 45
        {
            return .marker("-->")
        }
        if index + 1 < storage.length, storage.character(at: index + 1) == 63 {
            return .marker("?>")
        }
        if storage.substring(from: index).hasPrefix("<![CDATA[") {
            return .marker("]]>")
        }
        return .marker(">")
    }

    /// Whether the tag closes its `>` on this line and only whitespace follows
    /// (a "tag alone on the line" block start).
    func tagCompletesOnLine(in storage: NSString, at index: Int) -> Bool {
        var cursor = index + 1
        while cursor < storage.length {
            if storage.character(at: cursor) == 62 {
                return storage.substring(from: cursor + 1)
                    .trimmingCharacters(in: .whitespaces).isEmpty
            }
            cursor += 1
        }
        return false
    }

    // MARK: - container events (MDX)

    /// Opening tags push only when the line *starts* with a tag (block
    /// position); closing tags always pop a matching open so `<C>…</C>` on one
    /// line leaves no stale container.
    mutating func applyContainerEvents(
        _ events: [MathTagEvent], in line: MarkdownLine, context ctx: MathLineContext
    ) {
        let firstContent = line.range.location + ctx.contentIndex
        let startsWithTag = events.first?.range.location == firstContent
        for event in events {
            let head = event.head
            if head.isClosing {
                if let match = containerStack.lastIndex(where: { $0.name == head.name }) {
                    let open = containerStack[match]
                    containerZones.append(NSRange(
                        location: open.openLocation,
                        length: NSMaxRange(event.range) - open.openLocation
                    ))
                    containerStack.removeSubrange(match...)
                }
            } else if startsWithTag || event.openedAtBlockStart,
                      head.isContainerEligible, !event.isSelfContained
            {
                containerStack.append((name: head.name, openLocation: event.range.location))
            }
        }
    }

    static let rawTextTags: Set<String> = ["script", "pre", "style", "textarea"]

    /// CommonMark HTML block type-6 tag names.
    static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
        "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr",
        "track", "ul",
    ]
}

struct MathFence {
    let marker: unichar
    let count: Int
    let isMath: Bool
    let openLocation: Int
    let contentStart: Int
    let depth: Int
}

struct MathTagToken {
    let name: String
    let isClosing: Bool
    let isSelfContained: Bool
}
