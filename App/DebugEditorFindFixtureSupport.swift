#if DEBUG
    import Darwin
    import Foundation

    extension DebugEditorFindFixture {
        static func ownershipLeaseURL(
            for identifier: String,
            in fixturesRoot: URL
        ) -> URL {
            fixturesRoot.appendingPathComponent(
                leaseFilePrefix + identifier,
                isDirectory: false
            )
        }

        static func validatedIdentifier(_ identifier: String) throws -> String {
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

        static func validateFixturesRootIfPresent(
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
            case couldNotWriteLease(Int32)
            case couldNotReadLease(Int32)
        }
    }
#endif
