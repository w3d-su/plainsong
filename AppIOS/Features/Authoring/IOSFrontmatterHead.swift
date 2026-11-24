import Foundation
import MarkdownCore

/// The leading part of a document that alone decides its frontmatter parse: a closed
/// block through the terminator of its closing fence line. While that part is unchanged,
/// an edit to the body cannot change the parse, so the panel does not scan and load the
/// YAML again on every keystroke.
enum IOSFrontmatterHead {
    /// UTF-16 length of the head, or `nil` when `text` has no closed block ending in a
    /// line terminator (absent, unclosed, or a closing fence that is the last line and
    /// could still be extended).
    static func length(of text: String, parse: FrontmatterParseResult) -> Int? {
        guard let block = parse.block else { return nil }
        let storage = text as NSString
        guard storage.length >= 3 else { return nil }
        let marker = storage.substring(with: NSRange(location: 0, length: 3))
        guard marker == "---" || marker == "+++" else { return nil }
        var index = 3
        while index < storage.length, !isNewline(storage.character(at: index)) {
            index += 1
        }
        guard let opening = terminatorLength(at: index, in: storage) else { return nil }
        let closing = index + opening + (block.rawYAML as NSString).length
        guard closing + 3 <= storage.length,
              storage.substring(with: NSRange(location: closing, length: 3)) == marker
        else { return nil }
        index = closing + 3
        while index < storage.length, !isNewline(storage.character(at: index)) {
            let character = storage.character(at: index)
            guard character == 32 || character == 9 else { return nil }
            index += 1
        }
        guard let terminator = terminatorLength(at: index, in: storage) else { return nil }
        return index + terminator
    }

    /// Both texts start with the same `length` UTF-16 units.
    static func isShared(_ length: Int, by old: String, and new: String) -> Bool {
        let lhs = old.utf16.prefix(length)
        let rhs = new.utf16.prefix(length)
        return lhs.count == length && lhs.elementsEqual(rhs)
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private static func terminatorLength(at index: Int, in storage: NSString) -> Int? {
        guard index < storage.length else { return nil }
        switch storage.character(at: index) {
        case 13: return index + 1 < storage.length && storage.character(at: index + 1) == 10 ? 2 : 1
        case 10: return 1
        default: return nil
        }
    }
}
