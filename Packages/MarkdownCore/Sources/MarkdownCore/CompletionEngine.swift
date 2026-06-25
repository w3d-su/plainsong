import Foundation

public struct CompletionWorkspace: Equatable, Sendable {
    public var currentFilePath: String?
    public var markdownFilePaths: [String]
    public var imageFilePaths: [String]
    public var currentFileHeadingAnchors: [String]
    public var frontmatterKeys: [String]
    public var componentNames: [String]
    public var recentlyUsedCompletionIDs: [String]

    public init(
        currentFilePath: String? = nil,
        markdownFilePaths: [String] = [],
        imageFilePaths: [String] = [],
        currentFileHeadingAnchors: [String] = [],
        frontmatterKeys: [String] = [],
        componentNames: [String] = [],
        recentlyUsedCompletionIDs: [String] = []
    ) {
        self.currentFilePath = currentFilePath
        self.markdownFilePaths = markdownFilePaths
        self.imageFilePaths = imageFilePaths
        self.currentFileHeadingAnchors = currentFileHeadingAnchors
        self.frontmatterKeys = frontmatterKeys
        self.componentNames = componentNames
        self.recentlyUsedCompletionIDs = recentlyUsedCompletionIDs
    }

    public static let empty = CompletionWorkspace()

    var currentFileKind: FileKind {
        currentFilePath
            .flatMap { FileKind(fileExtension: ($0 as NSString).pathExtension) } ?? .markdown
    }
}

public struct Completion: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case snippet
        case language
        case filePath
        case imagePath
        case headingAnchor
        case emoji
        case frontmatterKey
        case component
    }

    public let id: String
    public let label: String
    public let insertText: String
    public let detail: String?
    public let kind: Kind
    public let replacementRange: NSRange

    public init(
        id: String? = nil,
        label: String,
        insertText: String,
        detail: String? = nil,
        kind: Kind,
        replacementRange: NSRange
    ) {
        self.id = id ?? "\(kind.rawValue):\(insertText)"
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.kind = kind
        self.replacementRange = replacementRange
    }
}

public struct CompletionEngine: Sendable {
    public init() {}

    public func complete(
        text: String,
        cursor: Int,
        workspace: CompletionWorkspace
    ) -> [Completion] {
        let storage = text as NSString
        let cursor = min(max(cursor, 0), storage.length)
        let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
        let prefixRange = NSRange(location: line.range.location, length: max(0, cursor - line.range.location))
        let linePrefix = MarkdownTextEditingSupport.substring(prefixRange, in: text)

        if let destinationContext = destinationContext(in: linePrefix, lineStart: line.range.location, cursor: cursor) {
            if destinationContext.isImage {
                return imageCompletions(context: destinationContext, workspace: workspace)
            }

            return linkCompletions(context: destinationContext, workspace: workspace)
        }

        if let emojiContext = emojiContext(in: linePrefix, lineStart: line.range.location, cursor: cursor) {
            return emojiCompletions(context: emojiContext, workspace: workspace)
        }

        if let fenceContext = fenceInfoContext(in: linePrefix, lineStart: line.range.location, cursor: cursor) {
            return languageCompletions(context: fenceContext, workspace: workspace)
        }

        if let frontmatterContext = frontmatterKeyContext(
            text: text,
            line: line,
            linePrefix: linePrefix,
            cursor: cursor
        ) {
            return frontmatterCompletions(context: frontmatterContext, workspace: workspace)
        }

        if let componentContext = componentContext(
            text: text,
            linePrefix: linePrefix,
            lineStart: line.range.location,
            cursor: cursor,
            workspace: workspace
        ) {
            return componentCompletions(context: componentContext, text: text, workspace: workspace)
        }

        if let snippetContext = lineStartContext(line: line, linePrefix: linePrefix, cursor: cursor) {
            return snippetCompletions(context: snippetContext)
        }

        return []
    }
}

struct CompletionContext {
    let query: String
    let replacementRange: NSRange
}

struct FenceMarker {
    let character: Character
    let length: Int
    let canClose: Bool
}

struct DestinationContext {
    let query: String
    let matchQuery: String
    let replacementRange: NSRange
    let prefixesDotSlash: Bool
    let isImage: Bool
}

struct RankedCompletion {
    let completion: Completion
    let matchText: String
    let order: Int
}
