#if DEBUG
    import Foundation

    /// Deterministic, app-container-owned fixture for out-of-process workspace-search UI tests.
    ///
    /// The fixture only creates files. Opening and searching continue through production
    /// `AppState`, `WorkspaceKit`, retained-authority, and editor-navigation paths.
    enum DebugWorkspaceSearchFixture {
        static let environmentKey = "PLAINSONG_DEBUG_WORKSPACE_SEARCH_FIXTURE"
        static let identifierPrefix = "ws4a-"
        static let staleFixtureAge: TimeInterval = 60 * 60

        static func create(
            identifier: String,
            fileManager: FileManager = .default,
            now: Date = Date()
        ) throws -> URL {
            let safeIdentifier = identifier
                .unicodeScalars
                .filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "-"
                        || scalar == "_"
                }
                .prefix(64)
            guard !safeIdentifier.isEmpty else {
                throw FixtureError.invalidIdentifier
            }

            let fixturesRoot = fileManager.temporaryDirectory
                .appendingPathComponent("PlainsongUITests", isDirectory: true)
            try removeStaleFixtures(
                in: fixturesRoot,
                excluding: String(String.UnicodeScalarView(Array(safeIdentifier))),
                fileManager: fileManager,
                now: now
            )
            let workspaceURL = fixturesRoot
                .appendingPathComponent(
                    String(String.UnicodeScalarView(Array(safeIdentifier))),
                    isDirectory: true
                )
            let postsURL = workspaceURL.appendingPathComponent("posts", isDirectory: true)

            if fileManager.fileExists(atPath: workspaceURL.path) {
                try fileManager.removeItem(at: workspaceURL)
            }
            try fileManager.createDirectory(at: postsURL, withIntermediateDirectories: true)

            try write(
                "前言\n搜尋 alpha\n",
                to: workspaceURL.appendingPathComponent("a-overview.md")
            )
            try write(
                "# 😀前言\n測試 搜尋 目標\n",
                to: postsURL.appendingPathComponent("b-target.mdx")
            )
            try write(
                "最後一篇：搜尋\n",
                to: workspaceURL.appendingPathComponent("z-last.md")
            )

            return workspaceURL
        }

        static func removeStaleFixtures(
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            fileManager: FileManager = .default,
            now: Date = Date()
        ) throws {
            guard fileManager.fileExists(atPath: fixturesRoot.path) else { return }
            let keys: Set<URLResourceKey> = [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
            let candidates = try fileManager.contentsOfDirectory(
                at: fixturesRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let staleBefore = now.addingTimeInterval(-staleFixtureAge)

            for candidate in candidates {
                guard candidate.lastPathComponent.hasPrefix(identifierPrefix),
                      candidate.lastPathComponent != currentIdentifier
                else {
                    continue
                }
                let values = try candidate.resourceValues(forKeys: keys)
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let modificationDate = values.contentModificationDate,
                      modificationDate <= staleBefore
                else {
                    continue
                }
                try fileManager.removeItem(at: candidate)
            }
        }

        private static func write(
            _ contents: String,
            to url: URL
        ) throws {
            try Data(contents.utf8).write(to: url, options: .atomic)
        }

        enum FixtureError: Error {
            case invalidIdentifier
        }
    }
#endif
