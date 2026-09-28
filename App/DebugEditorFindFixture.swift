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
            fileprivate var quarantineURL: URL?
            fileprivate var workspaceRemovalAttemptStarted = false
            fileprivate var workspaceWasVerifiedRemoved = false
            fileprivate var isVerifiedRemoved = false

            init(
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
                workspaceRemover: ((URL) throws -> Void)? = nil,
                afterRemovingWorkspaceChild:
                ((String) throws -> Void)? = nil,
                cleanupBoundaryHandler:
                EditorFindFixtureCleanupHandler? = nil
            ) throws {
                try DebugEditorFindFixture.removeCreatedFixture(
                    self,
                    fileManager: fileManager,
                    workspaceRemover: workspaceRemover,
                    afterRemovingWorkspaceChild:
                    afterRemovingWorkspaceChild,
                    cleanupBoundaryHandler: cleanupBoundaryHandler
                )
            }
        }
    }

    extension DebugEditorFindFixture {
        private static func removeCreatedFixture(
            _ fixture: CreatedFixture,
            fileManager _: FileManager,
            workspaceRemover: ((URL) throws -> Void)?,
            afterRemovingWorkspaceChild: ((String) throws -> Void)?,
            cleanupBoundaryHandler:
            EditorFindFixtureCleanupHandler?
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
            let rootHandle = try DebugEditorFindFixtureRootHandle(
                fixturesRoot: fixtureRoot,
                expectedIdentity: fixture.fixturesRootIdentity
            )
            if !fixture.workspaceWasVerifiedRemoved {
                try fixture.lease.validatePath()
                if fixture.workspaceRemovalAttemptStarted,
                   let quarantineURL = fixture.quarantineURL,
                   try entryMode(at: quarantineURL) == nil,
                   (try? fixture.workspaceHandle.verifyRemoved()) != nil
                {
                    fixture.workspaceWasVerifiedRemoved = true
                }
            }
            if !fixture.workspaceWasVerifiedRemoved {
                let quarantineURL = try preparedQuarantineURL(
                    for: fixture,
                    fixtureRoot: fixtureRoot,
                    workspaceURL: workspaceURL,
                    rootHandle: rootHandle,
                    cleanupBoundaryHandler: cleanupBoundaryHandler
                )
                try validateWorkspacePathForCleanup(
                    fixture,
                    at: quarantineURL
                )
                try cleanupBoundaryHandler?(
                    .willRemoveQuarantine(quarantineURL)
                )
                try rootHandle.validatePath()
                try validateWorkspacePathForCleanup(
                    fixture,
                    at: quarantineURL
                )
                try cleanupBoundaryHandler?(
                    .didValidateQuarantineForRemoval(quarantineURL)
                )
                fixture.workspaceRemovalAttemptStarted = true
                if let workspaceRemover {
                    try workspaceRemover(quarantineURL)
                } else {
                    try fixture.workspaceHandle.removeAnchored(
                        at: quarantineURL,
                        rootHandle: rootHandle,
                        afterRemovingChild:
                        afterRemovingWorkspaceChild,
                        cleanupBoundaryHandler:
                        cleanupBoundaryHandler
                    )
                }
                guard try entryMode(at: quarantineURL) == nil else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try fixture.workspaceHandle.verifyRemoved()
                fixture.workspaceWasVerifiedRemoved = true
            }
            try fixture.lease.unlinkPathIfStillOwned(
                cleanupBoundaryHandler: cleanupBoundaryHandler
            )
            fixture.isVerifiedRemoved = true
        }

        private static func preparedQuarantineURL(
            for fixture: CreatedFixture,
            fixtureRoot: URL,
            workspaceURL: URL,
            rootHandle: DebugEditorFindFixtureRootHandle,
            cleanupBoundaryHandler:
            EditorFindFixtureCleanupHandler?
        ) throws -> URL {
            if let quarantineURL = fixture.quarantineURL {
                if try entryMode(at: quarantineURL) != nil {
                    try validateWorkspacePathForCleanup(
                        fixture,
                        at: quarantineURL
                    )
                    return quarantineURL
                }
                fixture.quarantineURL = nil
            }

            guard let workspaceStatus = try entryStatus(at: workspaceURL) else {
                throw FixtureError.capturedWorkspaceMissing
            }
            guard fileType(of: workspaceStatus) == mode_t(S_IFDIR),
                  identity(of: workspaceStatus) == fixture.workspaceIdentity
            else {
                throw FixtureError.unsafeCreatedFixture
            }
            try fixture.workspaceHandle.validatePath(
                at: workspaceURL
            )
            let quarantineURL = try makeQuarantineURL(
                for: fixture.identifier,
                in: fixtureRoot
            )
            fixture.quarantineURL = quarantineURL
            try cleanupBoundaryHandler?(
                .willQuarantine(
                    source: workspaceURL,
                    destination: quarantineURL
                )
            )
            try rootHandle.quarantine(
                source: workspaceURL,
                destination: quarantineURL
            )
            try fixture.workspaceHandle.validatePath(
                at: quarantineURL
            )
            try cleanupBoundaryHandler?(
                .didQuarantine(
                    source: workspaceURL,
                    destination: quarantineURL
                )
            )
            try rootHandle.validatePath()
            try fixture.workspaceHandle.validatePath(
                at: quarantineURL
            )
            return quarantineURL
        }

        private static func validateWorkspacePathForCleanup(
            _ fixture: CreatedFixture,
            at workspaceURL: URL
        ) throws {
            if fixture.workspaceRemovalAttemptStarted {
                try fixture.workspaceHandle.validatePathForRemovalRetry(
                    at: workspaceURL
                )
            } else {
                try fixture.workspaceHandle.validatePath(at: workspaceURL)
            }
        }
    }

#endif
