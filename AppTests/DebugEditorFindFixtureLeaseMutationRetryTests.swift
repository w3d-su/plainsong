#if DEBUG
    @testable import Plainsong
    import XCTest

    private enum EditorFindLeaseMutationRetryTestError: Error {
        case afterRename
        case afterUnlink
    }

    final class DebugEditorFindFixtureLeaseMutationRetryTests: XCTestCase {
        func testLiveCleanupRetryReconcilesRenameThatSucceededBeforeFailure() throws {
            let fileManager = FileManager.default
            let locations = try makeLeaseMutationRetryLocations(prefix: "PostRename")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-lease-post-rename-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let publishedLease = DebugEditorFindFixture.ownershipLeaseURL(
                for: fixture.identifier,
                in: locations.root
            )
            var leaseQuarantine: URL?
            var injectedFailureCount = 0

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didRenameLeaseQuarantine(
                            _, destination
                        ) = boundary else { return }
                        leaseQuarantine = destination
                        injectedFailureCount += 1
                        throw EditorFindLeaseMutationRetryTestError.afterRename
                    }
                )
            ) { error in
                guard case EditorFindLeaseMutationRetryTestError.afterRename = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            let capturedQuarantine = try XCTUnwrap(leaseQuarantine)
            XCTAssertFalse(fileManager.fileExists(atPath: publishedLease.path))
            XCTAssertTrue(fileManager.fileExists(atPath: capturedQuarantine.path))

            try fixture.remove(fileManager: fileManager)

            XCTAssertEqual(injectedFailureCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: capturedQuarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: publishedLease.path))
        }

        func testLiveCleanupRetryReconcilesUnlinkThatSucceededBeforeFailure() throws {
            let fileManager = FileManager.default
            let locations = try makeLeaseMutationRetryLocations(prefix: "PostUnlink")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-lease-post-unlink-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let publishedLease = DebugEditorFindFixture.ownershipLeaseURL(
                for: fixture.identifier,
                in: locations.root
            )
            var leaseQuarantine: URL?
            var injectedFailureCount = 0

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didUnlinkLeaseQuarantine(url) = boundary
                        else { return }
                        leaseQuarantine = url
                        injectedFailureCount += 1
                        throw EditorFindLeaseMutationRetryTestError.afterUnlink
                    }
                )
            ) { error in
                guard case EditorFindLeaseMutationRetryTestError.afterUnlink = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            let capturedQuarantine = try XCTUnwrap(leaseQuarantine)
            XCTAssertFalse(fileManager.fileExists(atPath: capturedQuarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: publishedLease.path))

            try fixture.remove(fileManager: fileManager)
            try fixture.remove(fileManager: fileManager)

            XCTAssertEqual(injectedFailureCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: capturedQuarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: publishedLease.path))
        }

        func testOrphanSweepPreservesFreshReplacementSwappedAfterInspection() throws {
            let fileManager = FileManager.default
            let locations = try makeLeaseMutationRetryLocations(prefix: "OrphanSwap")
            defer { try? fileManager.removeItem(at: locations.container) }
            try fileManager.createDirectory(
                at: locations.root,
                withIntermediateDirectories: false
            )
            let identifier = "f9-orphan-swap-\(UUID().uuidString)"
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: locations.root
            )
            var lease: DebugEditorFindFixtureLease? =
                try DebugEditorFindFixtureLease.create(at: leaseURL)
            let now = Date()
            try makeLeaseMutationRetryEntryExpired(leaseURL, relativeTo: now)
            lease = nil
            let heldExact = locations.container.appendingPathComponent("held-exact-lease")
            var didSwap = false
            var replacementIdentity: DebugEditorFindFixture.EntryIdentity?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didInspectOrphanLease(inspectedURL) = boundary,
                              inspectedURL == leaseURL,
                              !didSwap
                        else { return }
                        didSwap = true
                        try fileManager.moveItem(at: leaseURL, to: heldExact)
                        XCTAssertTrue(
                            fileManager.createFile(
                                atPath: leaseURL.path,
                                contents: Data()
                            )
                        )
                        let replacementStatus = try XCTUnwrap(
                            DebugEditorFindFixture.entryStatus(at: leaseURL)
                        )
                        replacementIdentity = DebugEditorFindFixture.identity(
                            of: replacementStatus
                        )
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeLease = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            XCTAssertTrue(didSwap)
            let survivingStatus = try XCTUnwrap(
                DebugEditorFindFixture.entryStatus(at: leaseURL)
            )
            XCTAssertEqual(
                DebugEditorFindFixture.identity(of: survivingStatus),
                replacementIdentity
            )
            XCTAssertEqual(survivingStatus.st_size, 0)
            XCTAssertTrue(fileManager.fileExists(atPath: heldExact.path))
            XCTAssertNil(lease)
        }
    }

    private func makeLeaseMutationRetryLocations(
        prefix: String
    ) throws -> (container: URL, root: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EditorFindLease\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false
        )
        return (
            container,
            container.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
        )
    }

    private func makeLeaseMutationRetryEntryExpired(
        _ url: URL,
        relativeTo now: Date
    ) throws {
        try FileManager.default.setAttributes(
            [
                .modificationDate:
                    now.addingTimeInterval(
                        -DebugEditorFindFixture.staleFixtureAge - 1
                    ),
            ],
            ofItemAtPath: url.path
        )
    }
#endif
