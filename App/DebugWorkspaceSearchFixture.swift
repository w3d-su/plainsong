#if DEBUG
    import Foundation

    /// Deterministic, app-container-owned fixture for out-of-process workspace-search UI tests.
    ///
    /// The fixture only creates files. Opening and searching continue through production
    /// `AppState`, `WorkspaceKit`, retained-authority, and editor-navigation paths.
    enum DebugWorkspaceSearchFixture {
        static let environmentKey = "PLAINSONG_DEBUG_WORKSPACE_SEARCH_FIXTURE"

        static func create(
            identifier: String,
            fileManager: FileManager = .default
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
