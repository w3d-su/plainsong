import Foundation

struct MarkdownLine {
    let range: NSRange
    let fullRange: NSRange
    let text: String

    var endLocation: Int {
        range.location + range.length
    }

    var fullEndLocation: Int {
        fullRange.location + fullRange.length
    }
}

enum MarkdownTextEditingSupport {
    static func line(containing location: Int, in text: String) -> MarkdownLine {
        let storage = text as NSString
        let length = storage.length
        let clampedLocation = min(max(location, 0), length)

        var lineStart = clampedLocation
        if lineStart > 0, lineStart == length, isNewline(storage.character(at: lineStart - 1)) {
            return MarkdownLine(
                range: NSRange(location: length, length: 0),
                fullRange: NSRange(location: length, length: 0),
                text: ""
            )
        }

        while lineStart > 0, !isNewline(storage.character(at: lineStart - 1)) {
            lineStart -= 1
        }

        var lineEnd = clampedLocation
        while lineEnd < length, !isNewline(storage.character(at: lineEnd)) {
            lineEnd += 1
        }

        var fullEnd = lineEnd
        if fullEnd < length {
            let isCRLF = storage.character(at: fullEnd) == 13 &&
                fullEnd + 1 < length &&
                storage.character(at: fullEnd + 1) == 10
            if isCRLF {
                fullEnd += 2
            } else {
                fullEnd += 1
            }
        }

        let range = NSRange(location: lineStart, length: lineEnd - lineStart)
        return MarkdownLine(
            range: range,
            fullRange: NSRange(location: lineStart, length: fullEnd - lineStart),
            text: storage.substring(with: range)
        )
    }

    static func lines(overlapping selection: NSRange, in text: String) -> [MarkdownLine] {
        let storage = text as NSString
        let length = storage.length
        let start = min(max(selection.location, 0), length)
        let effectiveEnd: Int = if selection.length == 0 {
            start
        } else {
            min(max(selection.location + selection.length - 1, 0), length)
        }

        var lines: [MarkdownLine] = []
        var cursor = line(containing: start, in: text).range.location
        repeat {
            let nextLine = line(containing: cursor, in: text)
            lines.append(nextLine)
            let nextCursor = nextLine.fullEndLocation
            if nextCursor <= cursor || nextCursor >= effectiveEnd {
                break
            }
            cursor = nextCursor
        } while cursor <= length

        return lines
    }

    static func substring(_ range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: range)
    }

    static func character(at location: Int, in text: String) -> String? {
        let storage = text as NSString
        guard location >= 0, location < storage.length else { return nil }
        return storage.substring(with: NSRange(location: location, length: 1))
    }

    static func hasString(_ candidate: String, at location: Int, in text: String) -> Bool {
        let storage = text as NSString
        let length = (candidate as NSString).length
        guard location >= 0, location + length <= storage.length else { return false }
        return storage.substring(with: NSRange(location: location, length: length)) == candidate
    }

    static func replacement(
        range: NSRange,
        string: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        MarkdownEditResult(replacementRange: range, replacementString: string, newSelection: selection)
    }

    static func utf16Length(_ string: String) -> Int {
        (string as NSString).length
    }

    static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let end = min(max(location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }

    static func leadingWhitespaceLength(in line: String) -> Int {
        var length = 0
        for unit in line.utf16 {
            if unit == 32 || unit == 9 {
                length += 1
            } else {
                break
            }
        }
        return length
    }

    static func trimSpaces(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespaces)
    }

    static func isBlank(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 10 || unit == 13
    }
}
