import Foundation
import SwiftUI

// MARK: - UTF-16-safe snippet highlight (built lazily per visible row)

enum WorkspaceSearchSnippetHighlight {
    /// Builds an attributed snippet using UTF-16 `NSRange` boundaries (CJK/emoji/combining-safe).
    ///
    /// Call only from visible row rendering — never precompute for the full result set.
    static func attributedSnippet(
        _ snippet: String,
        matchRange: NSRange
    ) -> AttributedString {
        let nsSnippet = snippet as NSString
        let length = nsSnippet.length

        guard matchRange.location != NSNotFound,
              matchRange.location >= 0,
              matchRange.length >= 0,
              matchRange.location <= length,
              NSMaxRange(matchRange) <= length
        else {
            return AttributedString(snippet)
        }

        if matchRange.length == 0 {
            return AttributedString(snippet)
        }

        var result = AttributedString()

        if matchRange.location > 0 {
            let prefix = nsSnippet.substring(
                with: NSRange(location: 0, length: matchRange.location)
            )
            result += AttributedString(prefix)
        }

        var highlighted = AttributedString(nsSnippet.substring(with: matchRange))
        highlighted.backgroundColor = .yellow.opacity(0.35)
        // Match the row's `.callout` so the highlight does not jump to body size.
        highlighted.font = .callout.weight(.semibold)
        result += highlighted

        let after = NSMaxRange(matchRange)
        if after < length {
            let suffix = nsSnippet.substring(
                with: NSRange(location: after, length: length - after)
            )
            result += AttributedString(suffix)
        }

        return result
    }
}
