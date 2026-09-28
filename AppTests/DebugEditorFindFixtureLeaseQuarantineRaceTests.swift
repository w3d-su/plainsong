#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureLeaseQuarantineRaceTests: XCTestCase {
        func testLiveCleanupPreservesLeaseReplacementAfterQuarantineValidation() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "LiveLeaseRace")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-lease-race-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let heldLease = locations.container.appendingPathComponent("held-lease")
            var replacementURL: URL?

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didQuarantineLease(_, destination) = boundary
                        else { return }
                        try fileManager.moveItem(at: destination, to: heldLease)
                        try Data("replacement-lease".utf8).write(to: destination)
                        replacementURL = destination
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeLease = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let capturedReplacement = try XCTUnwrap(replacementURL)
            XCTAssertEqual(
                try String(contentsOf: capturedReplacement, encoding: .utf8),
                "replacement-lease"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: heldLease.path))
        }

        func testStaleSweepPreservesLeaseReplacementAfterQuarantineValidation() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "StaleLeaseRace")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-lease-race-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let now = Date()
            try makeRemovalRaceEntryExpired(workspaceURL, relativeTo: now)
            fixture = nil
            let heldLease = locations.container.appendingPathComponent("held-lease")
            var replacementURL: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didQuarantineLease(_, destination) = boundary
                        else { return }
                        try fileManager.moveItem(at: destination, to: heldLease)
                        try Data("replacement-lease".utf8).write(to: destination)
                        replacementURL = destination
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeLease = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let capturedReplacement = try XCTUnwrap(replacementURL)
            XCTAssertEqual(
                try String(contentsOf: capturedReplacement, encoding: .utf8),
                "replacement-lease"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: heldLease.path))
        }

        func testStaleSweepRecoversInterruptedExactLeaseQuarantine() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "LeaseRecovery")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-lease-recovery-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let now = Date()
            try makeRemovalRaceEntryExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var leaseQuarantineURL: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didQuarantineLease(_, destination) = boundary
                        else { return }
                        leaseQuarantineURL = destination
                        throw EditorFindRemovalRaceTestError
                            .afterLeaseQuarantine
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterLeaseQuarantine = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            let capturedLeaseQuarantine = try XCTUnwrap(leaseQuarantineURL)
            try makeRemovalRaceEntryExpired(
                capturedLeaseQuarantine,
                relativeTo: now
            )

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now
            )

            XCTAssertFalse(
                fileManager.fileExists(atPath: capturedLeaseQuarantine.path)
            )
        }

        func testOrphanLeaseSweepRejectsRootReplacementAndPreservesSentinel() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "LeaseRootRace")
            defer { try? fileManager.removeItem(at: locations.container) }
            try fileManager.createDirectory(
                at: locations.root,
                withIntermediateDirectories: false
            )
            let identifier = "f9-orphan-root-race-\(UUID().uuidString)"
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: locations.root
            )
            var lease: DebugEditorFindFixtureLease? =
                try DebugEditorFindFixtureLease.create(at: leaseURL)
            let now = Date()
            try makeRemovalRaceEntryExpired(leaseURL, relativeTo: now)
            lease = nil
            let heldRoot = locations.container.appendingPathComponent("held-root")
            var replacementSentinel: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .willQuarantineLease(source, _) = boundary
                        else { return }
                        try fileManager.moveItem(at: locations.root, to: heldRoot)
                        try fileManager.createDirectory(
                            at: locations.root,
                            withIntermediateDirectories: false
                        )
                        try Data("replacement-lease".utf8).write(to: source)
                        replacementSentinel = source
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let sentinel = try XCTUnwrap(replacementSentinel)
            XCTAssertEqual(
                try String(contentsOf: sentinel, encoding: .utf8),
                "replacement-lease"
            )
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: heldRoot.appendingPathComponent(
                        leaseURL.lastPathComponent
                    ).path
                )
            )
            XCTAssertNil(lease)
        }
    }
#endif
