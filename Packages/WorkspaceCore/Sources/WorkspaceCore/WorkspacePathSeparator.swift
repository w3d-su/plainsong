/// Path separator operations over UTF-8 bytes.
///
/// POSIX splits a path at every `0x2F` byte. Swift `String` compares extended grapheme
/// clusters, so `/` followed by a combining scalar is one `Character` that is not `"/"`:
/// `hasPrefix("/")`, `split(separator: "/")`, `contains("/")` and `lastIndex(of: "/")` all
/// miss a separator the kernel honors. Every path check that guards a syscall uses these.
public extension Substring {
    var hasLeadingPathSeparator: Bool {
        utf8.first == 0x2F
    }

    var hasTrailingPathSeparator: Bool {
        utf8.last == 0x2F
    }

    var containsPathSeparator: Bool {
        utf8.contains(0x2F)
    }

    var lastPathSeparatorIndex: Index? {
        utf8.lastIndex(of: 0x2F)
    }

    func splitOnPathSeparator(omittingEmptySubsequences: Bool = true) -> [Substring] {
        utf8.split(separator: 0x2F, omittingEmptySubsequences: omittingEmptySubsequences)
            .map { self[$0.startIndex ..< $0.endIndex] }
    }
}

public extension String {
    var hasLeadingPathSeparator: Bool {
        utf8.first == 0x2F
    }

    var hasTrailingPathSeparator: Bool {
        utf8.last == 0x2F
    }

    var containsPathSeparator: Bool {
        utf8.contains(0x2F)
    }

    var lastPathSeparatorIndex: Index? {
        utf8.lastIndex(of: 0x2F)
    }

    func splitOnPathSeparator(omittingEmptySubsequences: Bool = true) -> [Substring] {
        self[...].splitOnPathSeparator(omittingEmptySubsequences: omittingEmptySubsequences)
    }
}
