import Foundation

extension CompletionEngine {
    static let languageIDs = [
        "swift", "ts", "tsx", "js", "jsx", "python", "mermaid", "bash", "zsh", "json",
        "yaml", "html", "css", "go", "rust", "sql", "diff", "text",
    ]

    static let emojiShortcodes: [(name: String, character: String)] = [
        ("smile", "😄"),
        ("smiley", "😃"),
        ("sparkles", "✨"),
        ("heart", "❤️"),
        ("thumbsup", "👍"),
        ("warning", "⚠️"),
        ("rocket", "🚀"),
        ("white_check_mark", "✅"),
    ]

    static let builtInFrontmatterKeys = [
        "title", "description", "date", "tags", "draft", "slug",
    ]

    static let snippets: [(label: String, insertText: String)] = [
        ("Heading 1", "# "),
        ("Heading 2", "## "),
        ("Heading 3", "### "),
        ("Block Quote", "> "),
        ("Bullet List", "- "),
        ("Task Item", "- [ ] "),
        ("Table", "| Column | Column |\n| --- | --- |\n|  |  |"),
        ("Fenced Code Block", "```\n\n```"),
        ("Frontmatter Block", "---\ntitle: \ndescription: \ndate: \ntags: []\ndraft: false\nslug: \n---\n\n"),
    ]

    func languageCompletions(context: CompletionContext, workspace: CompletionWorkspace) -> [Completion] {
        let candidates = Self.languageIDs.enumerated().map { offset, language in
            RankedCompletion(
                completion: Completion(
                    label: language,
                    insertText: language,
                    kind: .language,
                    replacementRange: context.replacementRange
                ),
                matchText: language,
                order: offset
            )
        }
        return ranked(candidates, query: context.query, workspace: workspace)
    }

    func linkCompletions(context: DestinationContext, workspace: CompletionWorkspace) -> [Completion] {
        var candidates: [RankedCompletion] = []
        let paths = workspace.markdownFilePaths.map { ($0, Completion.Kind.filePath) } +
            workspace.imageFilePaths.map { ($0, Completion.Kind.imagePath) }

        for (offset, pathAndKind) in paths.enumerated() {
            let (path, kind) = pathAndKind
            let displayPath = context.prefixesDotSlash ? "./\(path)" : path
            candidates.append(RankedCompletion(
                completion: Completion(
                    id: "\(kind.rawValue):\(path)",
                    label: displayPath,
                    insertText: displayPath,
                    kind: kind,
                    replacementRange: context.replacementRange
                ),
                matchText: path,
                order: offset
            ))
        }

        let anchorOffset = candidates.count
        for (offset, anchor) in workspace.currentFileHeadingAnchors.enumerated() {
            candidates.append(RankedCompletion(
                completion: Completion(
                    label: anchor,
                    insertText: anchor,
                    kind: .headingAnchor,
                    replacementRange: context.replacementRange
                ),
                matchText: anchor,
                order: anchorOffset + offset
            ))
        }

        return ranked(candidates, query: context.matchQuery, workspace: workspace)
    }

    func imageCompletions(context: DestinationContext, workspace: CompletionWorkspace) -> [Completion] {
        let candidates = workspace.imageFilePaths.enumerated().map { offset, path in
            let displayPath = context.prefixesDotSlash ? "./\(path)" : path
            return RankedCompletion(
                completion: Completion(
                    id: "imagePath:\(path)",
                    label: displayPath,
                    insertText: displayPath,
                    kind: .imagePath,
                    replacementRange: context.replacementRange
                ),
                matchText: path,
                order: offset
            )
        }

        return ranked(candidates, query: context.matchQuery, workspace: workspace)
    }

    func emojiCompletions(context: CompletionContext, workspace: CompletionWorkspace) -> [Completion] {
        let candidates = Self.emojiShortcodes.enumerated().map { offset, emoji in
            RankedCompletion(
                completion: Completion(
                    id: "emoji:\(emoji.name)",
                    label: ":\(emoji.name):",
                    insertText: emoji.character,
                    kind: .emoji,
                    replacementRange: context.replacementRange
                ),
                matchText: emoji.name,
                order: offset
            )
        }

        return ranked(candidates, query: context.query, workspace: workspace)
    }

    func frontmatterCompletions(context: CompletionContext, workspace: CompletionWorkspace) -> [Completion] {
        let keys = unique(Self.builtInFrontmatterKeys + workspace.frontmatterKeys)
        let candidates = keys.enumerated().map { offset, key in
            RankedCompletion(
                completion: Completion(
                    label: key,
                    insertText: "\(key): ",
                    kind: .frontmatterKey,
                    replacementRange: context.replacementRange
                ),
                matchText: key,
                order: offset
            )
        }

        return ranked(candidates, query: context.query, workspace: workspace)
    }

    func componentCompletions(
        context: CompletionContext,
        text: String,
        workspace: CompletionWorkspace
    ) -> [Completion] {
        let names = unique(workspace.componentNames + MDXImportParser.componentNames(in: text))
        let candidates = names.enumerated().map { offset, name in
            RankedCompletion(
                completion: Completion(
                    label: name,
                    insertText: name,
                    kind: .component,
                    replacementRange: context.replacementRange
                ),
                matchText: name,
                order: offset
            )
        }

        return ranked(candidates, query: context.query, workspace: workspace)
    }

    func snippetCompletions(context: CompletionContext) -> [Completion] {
        var snippets = Self.snippets
        if context.replacementRange.location > 0 {
            snippets.removeAll { $0.label == "Frontmatter Block" }
        }

        return snippets.map { snippet in
            Completion(
                label: snippet.label,
                insertText: snippet.insertText,
                detail: "Markdown snippet",
                kind: .snippet,
                replacementRange: context.replacementRange
            )
        }
    }
}
