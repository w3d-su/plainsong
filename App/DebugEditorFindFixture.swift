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
        static let leaseFilePrefix = ".plainsong-editor-find-fixture-lease-"

        final class CreatedFixture {
            let identifier: String
            let workspaceURL: URL
            fileprivate let fixturesRoot: URL
            fileprivate let fixturesRootIdentity: EntryIdentity
            fileprivate let workspaceIdentity: EntryIdentity
            fileprivate let lease: DebugEditorFindFixtureLease
            fileprivate var workspaceWasVerifiedRemoved = false
            fileprivate var isVerifiedRemoved = false

            fileprivate init(
                identifier: String,
                workspaceURL: URL,
                fixturesRoot: URL,
                fixturesRootIdentity: EntryIdentity,
                workspaceIdentity: EntryIdentity,
                lease: DebugEditorFindFixtureLease
            ) {
                self.identifier = identifier
                self.workspaceURL = workspaceURL
                self.fixturesRoot = fixturesRoot
                self.fixturesRootIdentity = fixturesRootIdentity
                self.workspaceIdentity = workspaceIdentity
                self.lease = lease
            }

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
    }

    extension DebugEditorFindFixture {
        static func create(
            identifier: String,
            fileManager: FileManager = .default,
            now: Date = Date(),
            fixturesRootOverride: URL? = nil
        ) throws -> CreatedFixture {
            let currentIdentifier = try validatedIdentifier(identifier)
            let fixturesRoot = fixturesRootOverride?.standardizedFileURL
                ?? fixturesRoot(fileManager: fileManager)
            try createFixturesRootIfNeeded(
                fixturesRoot,
                fileManager: fileManager
            )
            try removeStaleFixtures(
                in: fixturesRoot,
                excluding: currentIdentifier,
                fileManager: fileManager,
                now: now
            )

            let workspaceURL = fixturesRoot
                .appendingPathComponent(currentIdentifier, isDirectory: true)
            guard let createdRootStatus = try entryStatus(at: fixturesRoot),
                  fileType(of: createdRootStatus) == mode_t(S_IFDIR)
            else {
                throw FixtureError.unsafeCreatedFixture
            }
            let createdRootIdentity = identity(of: createdRootStatus)
            let lease = try createOwnershipLease(
                identifier: currentIdentifier,
                fixturesRoot: fixturesRoot,
                workspaceURL: workspaceURL
            )
            var createdWorkspaceIdentity: EntryIdentity?
            do {
                try createWorkspaceDirectoryExclusively(workspaceURL)
                guard let createdWorkspaceStatus = try entryStatus(
                    at: workspaceURL
                ), fileType(of: createdWorkspaceStatus) == mode_t(S_IFDIR) else {
                    throw FixtureError.unsafeCreatedFixture
                }
                createdWorkspaceIdentity = identity(of: createdWorkspaceStatus)
                let exactMatches = """
                needle one
                needle two
                needle three
                caseprobe
                CASEPROBE
                wordprobe
                wordprobeTail
                headwordprobe
                """
                let overflowingMatches = String(repeating: "x ", count: 10001)
                try Data((exactMatches + "\n" + overflowingMatches).utf8).write(
                    to: workspaceURL.appendingPathComponent("editor-find.md"),
                    options: .atomic
                )
            } catch {
                if let createdWorkspaceIdentity {
                    removeFailedCreationIfStillOwned(
                        at: workspaceURL,
                        identity: createdWorkspaceIdentity,
                        fileManager: fileManager
                    )
                }
                try? lease.unlinkPathIfStillOwned()
                throw error
            }

            guard let createdWorkspaceIdentity else {
                throw FixtureError.unsafeCreatedFixture
            }
            guard let fixturesRootStatus = try entryStatus(at: fixturesRoot),
                  fileType(of: fixturesRootStatus) == mode_t(S_IFDIR),
                  identity(of: fixturesRootStatus) == createdRootIdentity,
                  let workspaceStatus = try entryStatus(at: workspaceURL),
                  fileType(of: workspaceStatus) == mode_t(S_IFDIR),
                  identity(of: workspaceStatus) == createdWorkspaceIdentity
            else {
                throw FixtureError.unsafeCreatedFixture
            }
            try lease.validatePath()
            return CreatedFixture(
                identifier: currentIdentifier,
                workspaceURL: workspaceURL,
                fixturesRoot: fixturesRoot,
                fixturesRootIdentity: identity(of: fixturesRootStatus),
                workspaceIdentity: createdWorkspaceIdentity,
                lease: lease
            )
        }

        private static func createOwnershipLease(
            identifier: String,
            fixturesRoot: URL,
            workspaceURL: URL
        ) throws -> DebugEditorFindFixtureLease {
            let leaseURL = ownershipLeaseURL(
                for: identifier,
                in: fixturesRoot
            )
            do {
                return try DebugEditorFindFixtureLease.create(at: leaseURL)
            } catch let FixtureError.couldNotCreateLease(errorCode) where errorCode == EEXIST {
                guard try entryMode(at: workspaceURL) == nil else {
                    throw FixtureError.fixtureAlreadyExists
                }
                guard let releasedLease = try DebugEditorFindFixtureLease
                    .tryAcquireExisting(at: leaseURL)
                else {
                    throw FixtureError.fixtureAlreadyExists
                }
                try releasedLease.unlinkPathIfStillOwned()
                return try DebugEditorFindFixtureLease.create(at: leaseURL)
            }
        }

        private static func removeFailedCreationIfStillOwned(
            at workspaceURL: URL,
            identity expectedIdentity: EntryIdentity,
            fileManager: FileManager
        ) {
            guard let status = try? entryStatus(at: workspaceURL),
                  fileType(of: status) == mode_t(S_IFDIR),
                  identity(of: status) == expectedIdentity
            else {
                return
            }
            try? fileManager.removeItem(at: workspaceURL)
        }

        private static func createFixturesRootIfNeeded(
            _ fixturesRoot: URL,
            fileManager: FileManager
        ) throws {
            if try validateFixturesRootIfPresent(
                fixturesRoot,
                fileManager: fileManager
            ) {
                return
            }
            let result = fixturesRoot.path.withCString {
                mkdir($0, mode_t(S_IRWXU))
            }
            guard result == 0 else {
                let errorCode = errno
                if errorCode == EEXIST,
                   try validateFixturesRootIfPresent(
                       fixturesRoot,
                       fileManager: fileManager
                   )
                {
                    return
                }
                throw FixtureError.couldNotCreateFixturesRoot(errorCode)
            }
        }

        private static func createWorkspaceDirectoryExclusively(
            _ workspaceURL: URL
        ) throws {
            let result = workspaceURL.path.withCString {
                mkdir($0, mode_t(S_IRWXU))
            }
            guard result == 0 else {
                let errorCode = errno
                if errorCode == EEXIST {
                    throw FixtureError.fixtureAlreadyExists
                }
                throw FixtureError.couldNotCreateWorkspace(errorCode)
            }
        }
    }

    extension DebugEditorFindFixture {
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
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
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
                guard let candidateStatus = try entryStatus(at: candidate),
                      fileType(of: candidateStatus) == mode_t(S_IFDIR)
                else {
                    continue
                }
                let candidateIdentity = identity(of: candidateStatus)
                let values = try candidate.resourceValues(forKeys: keys)
                guard let modificationDate = values.contentModificationDate,
                      modificationDate <= staleBefore
                else {
                    continue
                }

                let leaseURL = ownershipLeaseURL(
                    for: candidate.lastPathComponent,
                    in: fixturesRoot
                )
                guard let lease = try DebugEditorFindFixtureLease
                    .tryAcquireExisting(at: leaseURL)
                else {
                    // A locked lease belongs to a live or paused run. Missing or legacy
                    // leases are preserved because ownership cannot be proven.
                    continue
                }
                guard let revalidatedStatus = try entryStatus(at: candidate),
                      fileType(of: revalidatedStatus) == mode_t(S_IFDIR),
                      identity(of: revalidatedStatus) == candidateIdentity
                else {
                    continue
                }
                try lease.validatePath()
                try fileManager.removeItem(at: candidate)
                guard try entryMode(at: candidate) == nil,
                      try lease.linkCount() == 1
                else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try lease.unlinkPathIfStillOwned()
            }
        }
    }

    extension DebugEditorFindFixture {
        private static func removeCreatedFixture(
            _ fixture: CreatedFixture,
            fileManager: FileManager
        ) throws {
            if fixture.isVerifiedRemoved {
                return
            }
            let fixtureRoot = fixture.fixturesRoot.standardizedFileURL
            let workspaceURL = fixture.workspaceURL.standardizedFileURL
            guard fixture.identifier.hasPrefix(identifierPrefix),
                  fixture.identifier == workspaceURL.lastPathComponent,
                  workspaceURL.deletingLastPathComponent() == fixtureRoot
            else {
                throw FixtureError.unsafeCreatedFixture
            }

            guard let fixturesRootStatus = try entryStatus(at: fixtureRoot) else {
                throw FixtureError.capturedFixturesRootMissing
            }
            guard fileType(of: fixturesRootStatus) == mode_t(S_IFDIR),
                  identity(of: fixturesRootStatus) == fixture.fixturesRootIdentity
            else {
                throw FixtureError.unsafeFixturesRoot
            }
            if !fixture.workspaceWasVerifiedRemoved {
                try fixture.lease.validatePath()
                guard let workspaceStatus = try entryStatus(at: workspaceURL) else {
                    throw FixtureError.capturedWorkspaceMissing
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
                fixture.workspaceWasVerifiedRemoved = true
            }
            try fixture.lease.unlinkPathIfStillOwned()
            fixture.isVerifiedRemoved = true
        }
    }

    extension DebugEditorFindFixture {
        private static func fixturesRoot(fileManager: FileManager) -> URL {
            fileManager.temporaryDirectory
                .appendingPathComponent("PlainsongEditorFindUITests", isDirectory: true)
        }

        static func ownershipLeaseURL(
            for identifier: String,
            in fixturesRoot: URL
        ) -> URL {
            fixturesRoot.appendingPathComponent(
                leaseFilePrefix + identifier,
                isDirectory: false
            )
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

        static func cleanupPasteboardName(token: String) -> String {
            "app.plainsong.editor.debug.editor-find-cleanup.\(token)"
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

        struct EntryIdentity: Equatable {
            let device: dev_t
            let inode: ino_t
        }

        /// Returns the no-follow file type, including dangling symbolic links.
        static func entryMode(at url: URL) throws -> mode_t? {
            try entryStatus(at: url).map { fileType(of: $0) }
        }

        static func entryStatus(at url: URL) throws -> stat? {
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

        static func fileType(of fileStatus: stat) -> mode_t {
            fileStatus.st_mode & mode_t(S_IFMT)
        }

        static func identity(of fileStatus: stat) -> EntryIdentity {
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
            case capturedFixturesRootMissing
            case capturedWorkspaceMissing
            case fixtureRemovalDidNotComplete
            case couldNotInspectFixture(Int32)
            case couldNotCreateFixturesRoot(Int32)
            case couldNotCreateWorkspace(Int32)
            case couldNotCreateLease(Int32)
            case couldNotOpenLease(Int32)
            case couldNotLockLease(Int32)
            case couldNotRemoveLease(Int32)
            case unsafeLease
            case couldNotInspectLease(Int32)
        }
    }
#endif
