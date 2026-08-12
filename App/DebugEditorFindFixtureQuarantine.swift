#if DEBUG
    import Darwin
    import Foundation

    enum DebugEditorFindFixtureCleanupBoundary {
        case willQuarantine(source: URL, destination: URL)
        case didQuarantine(source: URL, destination: URL)
        case willRemoveQuarantine(URL)
        case didValidateQuarantineForRemoval(URL)
        case didUnlinkWorkspaceOwnershipMarker(URL)
        case didRejectStaleWorkspaceBinding(URL)
        case didInspectOrphanLease(URL)
        case willQuarantineLease(source: URL, destination: URL)
        case didRenameLeaseQuarantine(source: URL, destination: URL)
        case didQuarantineLease(source: URL, destination: URL)
        case didUnlinkLeaseQuarantine(URL)
    }

    typealias EditorFindFixtureCleanupHandler =
        (DebugEditorFindFixtureCleanupBoundary) throws -> Void

    extension DebugEditorFindFixture {
        static let quarantineFilePrefix =
            ".plainsong-editor-find-fixture-quarantine-"
        static let leaseQuarantineFilePrefix =
            ".plainsong-editor-find-fixture-lease-quarantine-"

        static func makeQuarantineURL(
            for identifier: String,
            in fixturesRoot: URL
        ) throws -> URL {
            let identifier = try validatedIdentifier(identifier)
            return fixturesRoot.appendingPathComponent(
                quarantineFilePrefix
                    + identifier
                    + "."
                    + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        }

        static func quarantinedFixtureIdentifier(
            from name: String
        ) -> String? {
            guard name.hasPrefix(quarantineFilePrefix) else {
                return nil
            }
            let suffix = name.dropFirst(quarantineFilePrefix.count)
            guard let separator = suffix.lastIndex(of: ".") else {
                return nil
            }
            let identifier = String(suffix[..<separator])
            let nonce = String(suffix[suffix.index(after: separator)...])
            guard UUID(uuidString: nonce) != nil,
                  (try? validatedIdentifier(identifier)) == identifier
            else {
                return nil
            }
            return identifier
        }

        static func makeLeaseQuarantineURL(
            for leaseURL: URL
        ) throws -> URL {
            let leaseName = leaseURL.lastPathComponent
            guard leaseName.hasPrefix(leaseFilePrefix) else {
                throw FixtureError.unsafeLease
            }
            let identifier = String(leaseName.dropFirst(leaseFilePrefix.count))
            _ = try validatedIdentifier(identifier)
            return leaseURL.deletingLastPathComponent().appendingPathComponent(
                leaseQuarantineFilePrefix
                    + identifier
                    + "."
                    + UUID().uuidString.lowercased(),
                isDirectory: false
            )
        }

        static func quarantinedLeaseIdentifier(
            from name: String
        ) -> String? {
            guard name.hasPrefix(leaseQuarantineFilePrefix) else {
                return nil
            }
            let suffix = name.dropFirst(leaseQuarantineFilePrefix.count)
            guard let separator = suffix.lastIndex(of: ".") else {
                return nil
            }
            let identifier = String(suffix[..<separator])
            let nonce = String(suffix[suffix.index(after: separator)...])
            guard UUID(uuidString: nonce) != nil,
                  (try? validatedIdentifier(identifier)) == identifier
            else {
                return nil
            }
            return identifier
        }
    }

#endif
