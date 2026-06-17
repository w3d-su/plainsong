import Foundation

public enum MDXImportParser {
    public static func componentNames(in text: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("import "),
                  let fromRange = line.range(of: " from ")
            else {
                continue
            }

            let clauseStart = line.index(line.startIndex, offsetBy: "import ".count)
            let clause = String(line[clauseStart ..< fromRange.lowerBound])
            for name in importedComponentNames(from: clause) where !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }

        return names
    }
}

private extension MDXImportParser {
    static func importedComponentNames(from clause: String) -> [String] {
        let trimmedClause = clause.trimmingCharacters(in: .whitespaces)
        guard !trimmedClause.hasPrefix("type ") else { return [] }

        // Braces identify the named group; comma splitting first would split pure named imports.
        if trimmedClause.hasPrefix("{") {
            return namedComponentNames(from: trimmedClause)
        }

        if let openBrace = trimmedClause.firstIndex(of: "{") {
            var defaultClause = String(trimmedClause[..<openBrace]).trimmingCharacters(in: .whitespaces)
            if defaultClause.hasSuffix(",") {
                defaultClause.removeLast()
            }
            return defaultComponentName(from: defaultClause) +
                namedComponentNames(from: String(trimmedClause[openBrace...]))
        }

        if let comma = trimmedClause.firstIndex(of: ",") {
            return defaultComponentName(from: String(trimmedClause[..<comma])) +
                namedComponentNames(from: String(trimmedClause[trimmedClause.index(after: comma)...]))
        }

        return defaultComponentName(from: trimmedClause)
    }

    static func defaultComponentName(from clause: String) -> [String] {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let name: String = if trimmed.hasPrefix("* as ") {
            String(trimmed.dropFirst("* as ".count))
        } else {
            trimmed
        }

        return isComponentName(name) ? [name] : []
    }

    static func namedComponentNames(from clause: String) -> [String] {
        guard let openBrace = clause.firstIndex(of: "{"),
              let closeBrace = clause[openBrace...].firstIndex(of: "}")
        else {
            return []
        }

        let imports = clause[clause.index(after: openBrace) ..< closeBrace]
        return imports.split(separator: ",").compactMap { rawImport -> String? in
            var name = rawImport.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("type ") {
                return nil
            }
            if let aliasRange = name.range(of: " as ") {
                name = String(name[aliasRange.upperBound...])
            }
            return isComponentName(name) ? name : nil
        }
    }

    static func isComponentName(_ name: String) -> Bool {
        guard let firstScalar = name.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(firstScalar)
    }
}
