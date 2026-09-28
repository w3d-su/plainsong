import Foundation

extension MathZones {
    func isTagStart(at index: Int, in storage: NSString) -> Bool {
        guard index + 1 < storage.length else { return false }
        let next = storage.character(at: index + 1)
        if next == 47 || next == 33 || next == 63 { return true }
        // `<>` fragments and `_` / `$` / non-ASCII names are JSX, not HTML.
        if fileKind == .mdx, next == 62 { return true }
        return isTagNameStart(next)
    }

    private func isTagNameStart(_ unit: unichar) -> Bool {
        if isASCIILetter(unit) { return true }
        guard fileKind == .mdx else { return false }
        return unit == 36 || unit == 95 || isUnicodeLetter(unit)
    }

    private func isTagNameCharacter(_ unit: unichar) -> Bool {
        if isASCIILetter(unit) || (unit >= 48 && unit <= 57) || unit == 45 { return true }
        guard fileKind == .mdx else { return false }
        // `.` (member) and `:` (namespace) join identifiers in JSX names.
        return unit == 36 || unit == 95 || unit == 46 || unit == 58 || isUnicodeLetter(unit)
    }

    private func isASCIILetter(_ unit: unichar) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    /// Parse `<`, `</`, `<>`, `<!`, `<?` plus the tag name and the character after it.
    func tagHead(at index: Int, in storage: NSString) -> MathTagHead? {
        var cursor = index + 1
        var isClosing = false
        if cursor < storage.length, storage.character(at: cursor) == 47 {
            isClosing = true
            cursor += 1
        }
        guard cursor < storage.length else { return nil }
        let first = storage.character(at: cursor)
        if !isClosing, first == 33 || first == 63 {
            return MathTagHead(
                name: "", rawName: "", isClosing: false,
                isStandalone: true, isContainerEligible: false
            )
        }
        // MDX fragments: `<>` and `</>`. CommonMark does not treat these as tags.
        if fileKind == .mdx, first == 62 {
            return MathTagHead(
                name: "", rawName: "", isClosing: isClosing,
                isStandalone: false, isContainerEligible: true
            )
        }
        guard isTagNameStart(first) else { return nil }
        var nameEnd = cursor
        while nameEnd < storage.length, isTagNameCharacter(storage.character(at: nameEnd)) {
            nameEnd += 1
        }
        let rawName = storage.substring(with: NSRange(location: cursor, length: nameEnd - cursor))
        let name = rawName.lowercased()
        let after = nameEnd < storage.length ? storage.character(at: nameEnd) : 0
        var eligible = after == 32 || after == 9 || after == 47 || after == 62 ||
            nameEnd == storage.length
        // A namespaced JSX name is exactly one `:` between two identifiers;
        // anything else (autolinks, `a:b:c`) is not a component container.
        if eligible, fileKind == .mdx, rawName.contains(":") {
            eligible = isValidJSXNamespacedName(rawName)
        }
        return MathTagHead(
            name: name, rawName: rawName, isClosing: isClosing,
            isStandalone: false, isContainerEligible: eligible
        )
    }

    /// `ns:Name` — exactly one `:` between two JSX identifiers. Each side uses
    /// JSX continuation (`-`, digits, `_`, `$`, Unicode), so `my-ui:Card` is
    /// a container and `https:` is not.
    private func isValidJSXNamespacedName(_ name: String) -> Bool {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            var iterator = part.utf16.makeIterator()
            guard let first = iterator.next(), isJSXNameStart(first) else { return false }
            while let unit = iterator.next() {
                guard isJSXNameContinue(unit) else { return false }
            }
            return true
        }
    }

    private func isJSXNameStart(_ unit: unichar) -> Bool {
        isASCIILetter(unit) || unit == 36 || unit == 95 || isUnicodeLetter(unit)
    }

    private func isJSXNameContinue(_ unit: unichar) -> Bool {
        // JSX identifiers allow `-` (`my-ui:Card`, `UI:my-card`), plus ZWJ/ZWNJ.
        if unit == 45 || unit == 0x200C || unit == 0x200D { return true }
        if isJSXNameStart(unit) || (unit >= 48 && unit <= 57) { return true }
        guard unit > 127, let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isXIDContinue
    }

    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    ]
}
