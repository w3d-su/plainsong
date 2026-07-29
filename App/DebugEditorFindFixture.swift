#if DEBUG
    import Darwin
    import Foundation

    /// Deterministic, app-container-owned fixture for out-of-process editor-find UI tests.
    ///
    /// The fixture only creates source files. Opening, matching, navigation, focus, and
    /// accessibility all continue through the launched app's production paths.
    enum DebugEditorFindFixture {
        static let environmentKey = "PLAINSONG_DEBUG_EDITOR_FIND_FIXTURE"
        static let cleanupTokenEnvironmentKey =
            "PLAINSONG_DEBUG_EDITOR_FIND_CLEANUP_TOKEN"
        static let cleanupReceiptPasteboardType =
            "app.plainsong.editor.debug.editor-find-cleanup"
        static let cleanupRequestPasteboardType =
            "app.plainsong.editor.debug.editor-find-cleanup-request"
        static let identifierPrefix = "f9-"
        static let staleFixtureAge: TimeInterval = 60 * 60

        struct CreatedFixture {
            let identifier: String
            let workspaceURL: URL
            fileprivate let fixturesRoot: URL
            fileprivate let fixturesRootIdentity: EntryIdentity
            fileprivate let workspaceIdentity: EntryIdentity

            /// Removes only the fixture represented by this app-created handle.
            ///
            /// The UI test never supplies a path to this operation. Revalidating the root,
            /// direct-child relationship, and entry type keeps a compromised or stale handle
            /// from widening deletion authority.
            func remove(fileManager: FileManager = .default) throws {
                try DebugEditorFindFixture.removeCreatedFixture(
                    self,
                    fileManager: fileManager
                )
            }
        }

        static func create(
            identifier: String,
            fileManager: FileManager = .default,
            now: Date = Date()
        ) throws -> CreatedFixture {
            let currentIdentifier = try validatedIdentifier(identifier)
            let fixturesRoot = fixturesRoot(fileManager: fileManager)
            try removeStaleFixtures(
                in: fixturesRoot,
                excluding: currentIdentifier,
                fileManager: fileManager,
                now: now
            )

            let workspaceURL = fixturesRoot
                .appendingPathComponent(currentIdentifier, isDirectory: true)
            if try entryMode(at: workspaceURL) != nil {
                throw FixtureError.fixtureAlreadyExists
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

            guard let fixturesRootStatus = try entryStatus(at: fixturesRoot),
                  fileType(of: fixturesRootStatus) == mode_t(S_IFDIR),
                  let workspaceStatus = try entryStatus(at: workspaceURL),
                  fileType(of: workspaceStatus) == mode_t(S_IFDIR)
            else {
                throw FixtureError.unsafeCreatedFixture
            }
            return CreatedFixture(
                identifier: currentIdentifier,
                workspaceURL: workspaceURL,
                fixturesRoot: fixturesRoot,
                fixturesRootIdentity: identity(of: fixturesRootStatus),
                workspaceIdentity: identity(of: workspaceStatus)
            )
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

        private static func removeCreatedFixture(
            _ fixture: CreatedFixture,
            fileManager: FileManager
        ) throws {
            let expectedRoot = fixturesRoot(fileManager: fileManager).standardizedFileURL
            let fixtureRoot = fixture.fixturesRoot.standardizedFileURL
            let workspaceURL = fixture.workspaceURL.standardizedFileURL
            guard fixture.identifier.hasPrefix(identifierPrefix),
                  fixture.identifier == workspaceURL.lastPathComponent,
                  workspaceURL.deletingLastPathComponent() == fixtureRoot,
                  fixtureRoot == expectedRoot
            else {
                throw FixtureError.unsafeCreatedFixture
            }

            guard let fixturesRootStatus = try entryStatus(at: fixtureRoot) else {
                return
            }
            guard fileType(of: fixturesRootStatus) == mode_t(S_IFDIR),
                  identity(of: fixturesRootStatus) == fixture.fixturesRootIdentity
            else {
                throw FixtureError.unsafeFixturesRoot
            }
            guard let workspaceStatus = try entryStatus(at: workspaceURL) else {
                return
            }
            guard fileType(of: workspaceStatus) == mode_t(S_IFDIR),
                  identity(of: workspaceStatus) == fixture.workspaceIdentity
            else {
                throw FixtureError.unsafeCreatedFixture
            }

            try fileManager.removeItem(at: workspaceURL)
            guard try entryMode(at: workspaceURL) == nil else {
                throw FixtureError.fixtureRemovalDidNotComplete
            }
        }

        private static func fixturesRoot(fileManager: FileManager) -> URL {
            fileManager.temporaryDirectory
                .appendingPathComponent("PlainsongEditorFindUITests", isDirectory: true)
        }

        private static func validatedIdentifier(_ identifier: String) throws -> String {
            let safeScalars = identifier.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-"
                    || scalar == "_"
            }
            guard !safeScalars.isEmpty,
                  safeScalars.count <= 64,
                  String(String.UnicodeScalarView(safeScalars)) == identifier,
                  identifier.hasPrefix(identifierPrefix)
            else {
                throw FixtureError.invalidIdentifier
            }
            return identifier
        }

        static func cleanupReceipt(identifier: String, token: String) -> String {
            "removed:\(identifier):\(token)"
        }

        static func cleanupRequest(identifier: String, token: String) -> String {
            "quit:\(identifier):\(token)"
        }

        static func cleanupRequestMatches(
            fixtureIdentifier: String,
            cleanupToken: String,
            request: String
        ) -> Bool {
            !cleanupToken.isEmpty
                && request == cleanupRequest(
                    identifier: fixtureIdentifier,
                    token: cleanupToken
                )
        }

        fileprivate struct EntryIdentity: Equatable {
            let device: dev_t
            let inode: ino_t
        }

        /// Returns the no-follow file type, including dangling symbolic links.
        private static func entryMode(at url: URL) throws -> mode_t? {
            try entryStatus(at: url).map { fileType(of: $0) }
        }

        private static func entryStatus(at url: URL) throws -> stat? {
            var fileStatus = stat()
            let result = url.path.withCString { path in
                lstat(path, &fileStatus)
            }
            guard result != 0 else {
                return fileStatus
            }
            let errorCode = errno
            guard errorCode == ENOENT else {
                throw FixtureError.couldNotInspectFixture(errorCode)
            }
            return nil
        }

        private static func fileType(of fileStatus: stat) -> mode_t {
            fileStatus.st_mode & mode_t(S_IFMT)
        }

        private static func identity(of fileStatus: stat) -> EntryIdentity {
            EntryIdentity(
                device: fileStatus.st_dev,
                inode: fileStatus.st_ino
            )
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
            case fixtureAlreadyExists
            case unsafeFixturesRoot
            case unsafeCreatedFixture
            case fixtureRemovalDidNotComplete
            case couldNotInspectFixture(Int32)
        }
    }
#endif
