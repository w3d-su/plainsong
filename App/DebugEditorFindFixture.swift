#if DEBUG
    import Darwin
    import Foundation

    /// Deterministic, app-container-owned fixture for out-of-process editor-find UI tests.
    ///
    /// The fixture creates isolated source plus private ownership metadata only. Opening,
    /// matching, navigation, focus, and accessibility continue through the launched app's
    /// production paths.
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
        static let ownershipMarkerFilePrefix =
            ".plainsong-editor-find-fixture-owner-"

        final class CreatedFixture {
            let identifier: String
            let workspaceURL: URL
            fileprivate let fixturesRoot: URL
            fileprivate let fixturesRootIdentity: EntryIdentity
            fileprivate let workspaceIdentity: EntryIdentity
            fileprivate let workspaceHandle: DebugEditorFindFixtureWorkspaceHandle
            fileprivate let lease: DebugEditorFindFixtureLease
            fileprivate var workspaceRemovalAttemptStarted = false
            fileprivate var workspaceWasVerifiedRemoved = false
            fileprivate var isVerifiedRemoved = false

            fileprivate init(
                identifier: String,
                workspaceURL: URL,
                fixturesRoot: URL,
                fixturesRootIdentity: EntryIdentity,
                workspaceIdentity: EntryIdentity,
                workspaceHandle: DebugEditorFindFixtureWorkspaceHandle,
                lease: DebugEditorFindFixtureLease
            ) {
                self.identifier = identifier
                self.workspaceURL = workspaceURL
                self.fixturesRoot = fixturesRoot
                self.fixturesRootIdentity = fixturesRootIdentity
                self.workspaceIdentity = workspaceIdentity
                self.workspaceHandle = workspaceHandle
                self.lease = lease
            }

            /// Removes only the fixture represented by this app-created handle.
            ///
            /// The UI test never supplies a path to this operation. Revalidating the root,
            /// direct-child relationship, and entry type keeps a compromised or stale handle
            /// from widening deletion authority.
            func remove(
                fileManager: FileManager = .default,
                workspaceRemover: ((URL) throws -> Void)? = nil
            ) throws {
                try DebugEditorFindFixture.removeCreatedFixture(
                    self,
                    fileManager: fileManager,
                    workspaceRemover: workspaceRemover
                )
            }
        }
    }

    extension DebugEditorFindFixture {
        static func create(
            identifier: String,
            fileManager: FileManager = .default,
            now: Date = Date(),
            fixturesRootOverride: URL? = nil,
            sourceWriter: ((Data, URL) throws -> Void)? = nil
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
            var didCreateWorkspaceDirectory = false
            var createdWorkspaceIdentity: EntryIdentity?
            var workspaceHandle: DebugEditorFindFixtureWorkspaceHandle?
            do {
                try createWorkspaceDirectoryExclusively(workspaceURL)
                didCreateWorkspaceDirectory = true
                guard let createdWorkspaceStatus = try entryStatus(
                    at: workspaceURL
                ), fileType(of: createdWorkspaceStatus) == mode_t(S_IFDIR) else {
                    throw FixtureError.unsafeCreatedFixture
                }
                let workspaceIdentity = identity(of: createdWorkspaceStatus)
                createdWorkspaceIdentity = workspaceIdentity
                let openedWorkspaceHandle =
                    try DebugEditorFindFixtureWorkspaceHandle.open(
                        at: workspaceURL,
                        expectedIdentity: workspaceIdentity
                    )
                workspaceHandle = openedWorkspaceHandle
                try lease.bindWorkspace(
                    openedWorkspaceHandle.workspaceBinding()
                )
                try writeFixtureSource(
                    in: workspaceURL,
                    sourceWriter: sourceWriter
                )
            } catch {
                var workspaceRemovalWasVerified = false
                if let createdWorkspaceIdentity {
                    workspaceRemovalWasVerified = removeFailedCreationIfStillOwned(
                        at: workspaceURL,
                        identity: createdWorkspaceIdentity,
                        fileManager: fileManager
                    )
                    if workspaceRemovalWasVerified,
                       let workspaceHandle
                    {
                        workspaceRemovalWasVerified =
                            (try? workspaceHandle.verifyRemoved()) != nil
                    }
                }
                if workspaceRemovalWasVerified {
                    try? lease.unlinkPathIfStillOwned()
                } else if !didCreateWorkspaceDirectory {
                    // The conflicting workspace predates this attempt. Remove only the
                    // exact lease this attempt created so a later stale sweep cannot
                    // misclassify that unleased directory as app-owned.
                    try? lease.unlinkPathIfStillOwned()
                }
                throw error
            }

            guard let createdWorkspaceIdentity,
                  let workspaceHandle
            else {
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
                workspaceHandle: workspaceHandle,
                lease: lease
            )
        }

        private static func writeFixtureSource(
            in workspaceURL: URL,
            sourceWriter: ((Data, URL) throws -> Void)?
        ) throws {
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
            let source = Data(
                (exactMatches + "\n" + overflowingMatches).utf8
            )
            let sourceURL = workspaceURL.appendingPathComponent(
                "editor-find.md"
            )
            if let sourceWriter {
                try sourceWriter(source, sourceURL)
            } else {
                try source.write(to: sourceURL, options: .atomic)
            }
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
                guard try releasedLease.workspaceBinding() == nil else {
                    // A bound lease can represent a captured workspace that was
                    // renamed away. Its missing published name is not proof that
                    // the captured fixture was removed.
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
        ) -> Bool {
            guard let status = try? entryStatus(at: workspaceURL),
                  fileType(of: status) == mode_t(S_IFDIR),
                  identity(of: status) == expectedIdentity
            else {
                return false
            }
            do {
                try fileManager.removeItem(at: workspaceURL)
                return try entryMode(at: workspaceURL) == nil
            } catch {
                return false
            }
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
        private static func removeCreatedFixture(
            _ fixture: CreatedFixture,
            fileManager: FileManager,
            workspaceRemover: ((URL) throws -> Void)?
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
                try fixture.workspaceHandle.validatePath(
                    allowingRemovedOwnershipMarker:
                    fixture.workspaceRemovalAttemptStarted
                )
                fixture.workspaceRemovalAttemptStarted = true
                if let workspaceRemover {
                    try workspaceRemover(workspaceURL)
                } else {
                    try fileManager.removeItem(at: workspaceURL)
                }
                guard try entryMode(at: workspaceURL) == nil else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try fixture.workspaceHandle.verifyRemoved()
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
    }
#endif
