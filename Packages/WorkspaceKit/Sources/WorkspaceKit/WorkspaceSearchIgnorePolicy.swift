import Foundation

/// The documented, bounded subset of root and nested `.gitignore` / `.ignore` handling.
struct WorkspaceSearchIgnorePolicy {
    private let rules: [WorkspaceSearchIgnoreRule]

    static func load(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        candidatePaths: [String],
        limits: WorkspaceSearchLimits,
        reader: any WorkspaceSearchFileReading
    ) async throws -> WorkspaceSearchIgnorePolicy {
        guard limits.maximumIgnoreFiles > 0, limits.maximumIgnoreFileSizeBytes >= 0 else {
            return WorkspaceSearchIgnorePolicy(rules: [])
        }

        let directories = ancestorDirectories(for: candidatePaths)
        let readLimit = inclusiveLimit(for: limits.maximumIgnoreFileSizeBytes)
        var reads = 0
        var rules: [WorkspaceSearchIgnoreRule] = []

        outer: for directory in directories {
            for filename in [".gitignore", ".ignore"] {
                guard reads < limits.maximumIgnoreFiles else { break outer }
                try Task.checkCancellation()

                let relativePath = directory.isEmpty ? filename : "\(directory)/\(filename)"
                guard let location = try? rootAuthority.location(relativePath: relativePath) else {
                    continue
                }

                reads += 1
                let data: Data
                do {
                    data = try await reader.readFile(
                        at: location,
                        maximumByteCount: readLimit
                    )
                } catch let error as CancellationError {
                    throw error
                } catch {
                    continue
                }
                guard data.count <= limits.maximumIgnoreFileSizeBytes,
                      let contents = String(data: data, encoding: .utf8)
                else {
                    continue
                }
                try Task.checkCancellation()
                rules.append(contentsOf: WorkspaceSearchIgnoreRule.parse(contents, baseDirectory: directory))
            }
        }

        return WorkspaceSearchIgnorePolicy(rules: rules)
    }

    func isIgnored(relativePath: String) -> Bool {
        var isIgnored = false
        for rule in rules where rule.matches(relativePath: relativePath) {
            isIgnored = !rule.isNegated
        }
        return isIgnored
    }

    private static func ancestorDirectories(for paths: [String]) -> [String] {
        var directories = [WorkspacePathByteKey(""): ""]
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { continue }

            var directory = ""
            for component in components.dropLast() {
                directory = directory.isEmpty ? String(component) : "\(directory)/\(component)"
                directories[WorkspacePathByteKey(directory)] = directory
            }
        }

        return directories.values.sorted { first, second in
            let firstDepth = first.split(separator: "/", omittingEmptySubsequences: true).count
            let secondDepth = second.split(separator: "/", omittingEmptySubsequences: true).count
            return firstDepth == secondDepth
                ? WorkspacePathByteKey(first) < WorkspacePathByteKey(second)
                : firstDepth < secondDepth
        }
    }

    private static func inclusiveLimit(for limit: Int) -> Int {
        guard limit < Int.max else { return limit }
        return limit + 1
    }
}

private struct WorkspaceSearchIgnoreRule {
    let baseDirectory: String
    let pattern: String
    let isNegated: Bool
    let isRooted: Bool
    let isDirectoryOnly: Bool
    let hasPathSeparator: Bool

    static func parse(_ contents: String, baseDirectory: String) -> [WorkspaceSearchIgnoreRule] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            let isNegated = line.removeFirstIfPresent("!")
            let isRooted = line.removeFirstIfPresent("/")
            let isDirectoryOnly = line.removeLastIfPresent("/")
            guard !line.isEmpty else { return nil }

            return WorkspaceSearchIgnoreRule(
                baseDirectory: baseDirectory,
                pattern: line,
                isNegated: isNegated,
                isRooted: isRooted,
                isDirectoryOnly: isDirectoryOnly,
                hasPathSeparator: line.contains("/")
            )
        }
    }

    func matches(relativePath: String) -> Bool {
        guard let localPath = pathRelativeToBase(relativePath) else { return false }

        if isDirectoryOnly {
            return directoryPrefixes(of: localPath).contains { matchesTarget($0) }
        }
        return matchesTarget(localPath)
    }

    private func pathRelativeToBase(_ relativePath: String) -> String? {
        guard !baseDirectory.isEmpty else { return relativePath }
        let prefix = "\(baseDirectory)/"
        guard relativePath.utf8.starts(with: prefix.utf8) else { return nil }
        return String(relativePath.dropFirst(prefix.count))
    }

    private func directoryPrefixes(of path: String) -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return [] }

        var result: [String] = []
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            result.append(current)
        }
        return result
    }

    private func matchesTarget(_ path: String) -> Bool {
        if isRooted || hasPathSeparator {
            return WorkspaceSearchGlob.matches(pathPattern: pattern, path: path)
        }

        return path.split(separator: "/", omittingEmptySubsequences: true).contains { component in
            WorkspaceSearchGlob.matchesComponent(pattern: pattern, value: String(component))
        }
    }
}

private enum WorkspaceSearchGlob {
    static func matches(pathPattern: String, path: String) -> Bool {
        let patternComponents = pathPattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var cache: [String: Bool] = [:]

        func match(_ patternIndex: Int, _ pathIndex: Int) -> Bool {
            let key = "\(patternIndex):\(pathIndex)"
            if let cached = cache[key] { return cached }

            let value: Bool = if patternIndex == patternComponents.count {
                pathIndex == pathComponents.count
            } else if patternComponents[patternIndex] == "**" {
                if patternIndex + 1 == patternComponents.count {
                    true
                } else {
                    (pathIndex ... pathComponents.count).contains {
                        match(patternIndex + 1, $0)
                    }
                }
            } else if pathIndex < pathComponents.count,
                      matchesComponent(pattern: patternComponents[patternIndex], value: pathComponents[pathIndex])
            {
                match(patternIndex + 1, pathIndex + 1)
            } else {
                false
            }
            cache[key] = value
            return value
        }

        return match(0, 0)
    }

    static func matchesComponent(pattern: String, value: String) -> Bool {
        let patternCharacters = Array(pattern)
        let valueCharacters = Array(value)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var retryValueIndex = 0

        while valueIndex < valueCharacters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == "?" || patternCharacters[patternIndex] == valueCharacters[valueIndex]
            {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                patternIndex += 1
                retryValueIndex = valueIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                retryValueIndex += 1
                valueIndex = retryValueIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}

private extension String {
    mutating func removeFirstIfPresent(_ character: Character) -> Bool {
        guard first == character else { return false }
        removeFirst()
        return true
    }

    mutating func removeLastIfPresent(_ character: Character) -> Bool {
        guard last == character else { return false }
        removeLast()
        return true
    }
}
