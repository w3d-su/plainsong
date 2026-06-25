import Foundation

extension CompletionEngine {
    func destinationContext(
        in linePrefix: String,
        lineStart _: Int,
        cursor: Int
    ) -> DestinationContext? {
        guard let bracketParen = linePrefix.range(of: "](", options: .backwards) else {
            return nil
        }

        let beforeBracket = String(linePrefix[..<bracketParen.lowerBound])
        let query = String(linePrefix[bracketParen.upperBound...])
        guard !query.contains(where: { $0.isWhitespace || $0 == ")" }) else {
            return nil
        }

        let queryLength = MarkdownTextEditingSupport.utf16Length(query)
        let prefixesDotSlash = query.hasPrefix("./")
        let matchQuery = prefixesDotSlash ? String(query.dropFirst(2)) : query
        return DestinationContext(
            query: query,
            matchQuery: matchQuery,
            replacementRange: NSRange(location: cursor - queryLength, length: queryLength),
            prefixesDotSlash: prefixesDotSlash,
            isImage: isImageDestination(beforeBracket: beforeBracket)
        )
    }

    func isImageDestination(beforeBracket: String) -> Bool {
        guard let openBracket = beforeBracket.range(of: "[", options: .backwards) else {
            return false
        }
        guard openBracket.lowerBound > beforeBracket.startIndex else {
            return false
        }

        let previousIndex = beforeBracket.index(before: openBracket.lowerBound)
        return beforeBracket[previousIndex] == "!"
    }

    func emojiContext(
        in linePrefix: String,
        lineStart: Int,
        cursor: Int
    ) -> CompletionContext? {
        guard let colon = linePrefix.range(of: ":", options: .backwards) else {
            return nil
        }

        let query = String(linePrefix[colon.upperBound...])
        guard query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" }) else {
            return nil
        }

        let colonOffset = MarkdownTextEditingSupport.utf16Length(String(linePrefix[..<colon.lowerBound]))
        let location = lineStart + colonOffset
        return CompletionContext(
            query: query,
            replacementRange: NSRange(location: location, length: cursor - location)
        )
    }

    func fenceInfoContext(
        in linePrefix: String,
        lineStart: Int,
        cursor: Int
    ) -> CompletionContext? {
        let leadingWhitespace = MarkdownTextEditingSupport.leadingWhitespaceLength(in: linePrefix)
        let contentStart = linePrefix.index(linePrefix.startIndex, offsetBy: leadingWhitespace)
        let content = String(linePrefix[contentStart...])
        let marker: String

        if content.hasPrefix("```") {
            marker = "```"
        } else if content.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }

        let query = String(content.dropFirst(marker.count))
        guard !query.contains(where: \.isWhitespace) else { return nil }

        let location = lineStart + leadingWhitespace + MarkdownTextEditingSupport.utf16Length(marker)
        return CompletionContext(
            query: query,
            replacementRange: NSRange(location: location, length: cursor - location)
        )
    }

    func frontmatterKeyContext(
        text: String,
        line: MarkdownLine,
        linePrefix: String,
        cursor: Int
    ) -> CompletionContext? {
        guard line.text.trimmingCharacters(in: .whitespaces) != "---" else {
            return nil
        }

        guard isInsideFrontmatter(text: text, cursor: cursor) else {
            return nil
        }

        let leadingWhitespace = MarkdownTextEditingSupport.leadingWhitespaceLength(in: linePrefix)
        let contentStart = linePrefix.index(linePrefix.startIndex, offsetBy: leadingWhitespace)
        let query = String(linePrefix[contentStart...])
        guard !query.contains(":"),
              query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else {
            return nil
        }

        let location = line.range.location + leadingWhitespace
        return CompletionContext(
            query: query,
            replacementRange: NSRange(location: location, length: cursor - location)
        )
    }

    func isInsideFrontmatter(text: String, cursor: Int) -> Bool {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
            return false
        }

        let storage = text as NSString
        let length = storage.length
        let firstLine = MarkdownTextEditingSupport.line(containing: 0, in: text)
        guard cursor >= firstLine.fullEndLocation else {
            return false
        }

        var lineStart = firstLine.fullEndLocation

        while lineStart < length {
            let line = MarkdownTextEditingSupport.line(containing: lineStart, in: text)
            if line.text.trimmingCharacters(in: .whitespaces) == "---" {
                return cursor < line.range.location
            }

            if line.range.location >= cursor {
                return true
            }

            if cursor <= line.fullEndLocation {
                return true
            }

            let nextLineStart = line.fullEndLocation
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
        }

        return cursor >= firstLine.fullEndLocation
    }

    func componentContext(
        text: String,
        linePrefix: String,
        lineStart: Int,
        cursor: Int,
        workspace: CompletionWorkspace
    ) -> CompletionContext? {
        guard workspace.currentFileKind == .mdx,
              let openAngle = linePrefix.range(of: "<", options: .backwards),
              !isInsideFencedCodeBlock(text: text, cursor: cursor)
        else {
            return nil
        }

        let query = String(linePrefix[openAngle.upperBound...])
        guard !query.hasPrefix("/"),
              query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        else {
            return nil
        }

        let queryStart = MarkdownTextEditingSupport.utf16Length(String(linePrefix[..<openAngle.upperBound]))
        let location = lineStart + queryStart
        return CompletionContext(
            query: query,
            replacementRange: NSRange(location: location, length: cursor - location)
        )
    }

    func isInsideFencedCodeBlock(text: String, cursor: Int) -> Bool {
        let storage = text as NSString
        let length = storage.length
        let cursor = min(max(cursor, 0), length)
        var lineStart = 0
        var openFence: FenceMarker?

        while lineStart < cursor {
            let line = MarkdownTextEditingSupport.line(containing: lineStart, in: text)
            if let fence = fenceMarker(in: line.text) {
                if let currentFence = openFence {
                    if fence.character == currentFence.character,
                       fence.length >= currentFence.length,
                       fence.canClose
                    {
                        openFence = nil
                    }
                } else {
                    openFence = fence
                }
            }

            let nextLineStart = line.fullEndLocation
            guard nextLineStart > lineStart else { break }
            lineStart = nextLineStart
        }

        return openFence != nil
    }

    func fenceMarker(in line: String) -> FenceMarker? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return nil }
            index = line.index(after: index)
        }

        guard index < line.endIndex,
              line[index] == "`" || line[index] == "~"
        else {
            return nil
        }

        let character = line[index]
        var markerEnd = index
        var markerLength = 0
        while markerEnd < line.endIndex, line[markerEnd] == character {
            markerLength += 1
            markerEnd = line.index(after: markerEnd)
        }
        guard markerLength >= 3 else { return nil }

        let rest = String(line[markerEnd...])
        return FenceMarker(
            character: character,
            length: markerLength,
            canClose: rest.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    func lineStartContext(
        line: MarkdownLine,
        linePrefix: String,
        cursor: Int
    ) -> CompletionContext? {
        let leadingWhitespace = MarkdownTextEditingSupport.leadingWhitespaceLength(in: linePrefix)
        let contentStart = linePrefix.index(linePrefix.startIndex, offsetBy: leadingWhitespace)
        let query = String(linePrefix[contentStart...])
        guard query.isEmpty || query.allSatisfy({ "#>-".contains($0) }) else {
            return nil
        }

        let location = line.range.location + leadingWhitespace
        return CompletionContext(
            query: query,
            replacementRange: NSRange(location: location, length: cursor - location)
        )
    }
}
