#if DEBUG
    import Foundation

    /// Deterministic, app-container-owned fixture for out-of-process editor-find UI tests.
    ///
    /// The fixture only creates source files. Opening, matching, navigation, focus, and
    /// accessibility all continue through the launched app's production paths.
    enum DebugEditorFindFixture {
        static let environmentKey = "PLAINSONG_DEBUG_EDITOR_FIND_FIXTURE"
        static let identifierPrefix = "f9-"
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

            let currentIdentifier = String(String.UnicodeScalarView(Array(safeIdentifier)))
            let fixturesRoot = fileManager.temporaryDirectory
                .appendingPathComponent("PlainsongEditorFindUITests", isDirectory: true)
            try removeStaleFixtures(
                in: fixturesRoot,
                excluding: currentIdentifier,
                fileManager: fileManager,
                now: now
            )

            let workspaceURL = fixturesRoot
                .appendingPathComponent(currentIdentifier, isDirectory: true)
            if fileManager.fileExists(atPath: workspaceURL.path) {
                try fileManager.removeItem(at: workspaceURL)
            }
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true
            )

            let exactMatches = """
            needle one
            needle two
            needle three

            """
            let overflowingMatches = String(repeating: "x ", count: 10001)
            try Data((exactMatches + overflowingMatches).utf8).write(
                to: workspaceURL.appendingPathComponent("editor-find.md"),
                options: .atomic
            )

            return workspaceURL
        }

        static func removeStaleFixtures(
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            fileManager: FileManager = .default,
            now: Date = Date()
        ) throws {
            guard try validateFixturesRootIfPresent(
                fixturesRoot,
                fileManager: fileManager
            ) else {
                return
            }
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

        private static func validateFixturesRootIfPresent(
            _ fixturesRoot: URL,
            fileManager: FileManager
        ) throws -> Bool {
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: fixturesRoot.path
            )) != nil {
                throw FixtureError.unsafeFixturesRoot
            }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: fixturesRoot.path,
                isDirectory: &isDirectory
            ) else {
                return false
            }
            let values = try fixturesRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw FixtureError.unsafeFixturesRoot
            }
            return true
        }

        enum FixtureError: Error {
            case invalidIdentifier
            case unsafeFixturesRoot
        }
    }
#endif
