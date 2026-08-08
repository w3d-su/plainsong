#if DEBUG
    @testable import Plainsong
    import XCTest

    private enum EditorFindRemovalRaceTestError: Error {
        case afterMarkerReplacement
        case afterKnownChildRemoval
        case afterLeaseQuarantine
        case afterOwnershipMarkerUnlink
    }

    final class DebugEditorFindFixtureRemovalRetryTests: XCTestCase {
        func testRetryPreservesReplacementMarkerAfterPartialRemovalThrows() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "MarkerReplacement")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-marker-replacement-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: fixture.identifier,
                in: locations.root
            )
            var replacementMarkerURL: URL?

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    workspaceRemover: { quarantineURL in
                        let markerURL = try XCTUnwrap(
                            fileManager.contentsOfDirectory(
                                at: quarantineURL,
                                includingPropertiesForKeys: nil
                            ).first {
                                $0.lastPathComponent.hasPrefix(
                                    DebugEditorFindFixture.ownershipMarkerFilePrefix
                                )
                            }
                        )
                        try fileManager.removeItem(at: markerURL)
                        try Data("replacement-marker".utf8).write(to: markerURL)
                        replacementMarkerURL = markerURL
                        throw EditorFindRemovalRaceTestError
                            .afterMarkerReplacement
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterMarkerReplacement = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            XCTAssertThrowsError(
                try fixture.remove(fileManager: fileManager)
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            let markerURL = try XCTUnwrap(replacementMarkerURL)
            XCTAssertEqual(
                try String(contentsOf: markerURL, encoding: .utf8),
                "replacement-marker"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testAnchoredRemovalRetryReenumeratesAfterPartialFailure() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(prefix: "PartialRetry")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-partial-retry-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let removedName = "00-known-removed"
            let failureName = "01-injected-failure"
            try Data("remove".utf8).write(
                to: fixture.workspaceURL.appendingPathComponent(removedName)
            )
            try Data("fail-after-remove".utf8).write(
                to: fixture.workspaceURL.appendingPathComponent(failureName)
            )
            var quarantineURL: URL?
            var observedRemovedNames = [String]()

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    afterRemovingWorkspaceChild: { name in
                        observedRemovedNames.append(name)
                        if name == failureName {
                            XCTAssertEqual(
                                observedRemovedNames,
                                [removedName, failureName]
                            )
                            throw EditorFindRemovalRaceTestError
                                .afterKnownChildRemoval
                        }
                    },
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didQuarantine(_, destination) = boundary
                        else { return }
                        quarantineURL = destination
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterKnownChildRemoval = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            let capturedQuarantine = try XCTUnwrap(quarantineURL)
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: capturedQuarantine
                        .appendingPathComponent(removedName).path
                )
            )
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: capturedQuarantine
                        .appendingPathComponent(failureName).path
                )
            )
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: capturedQuarantine
                        .appendingPathComponent("editor-find.md").path
                )
            )

            try fixture.remove(fileManager: fileManager)

            XCTAssertFalse(
                fileManager.fileExists(atPath: capturedQuarantine.path)
            )
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: DebugEditorFindFixture.ownershipLeaseURL(
                        for: fixture.identifier,
                        in: locations.root
                    ).path
                )
            )
        }

        func testLiveCleanupRetriesAfterOwnershipMarkerUnlink() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(
                prefix: "MarkerUnlinkRetry"
            )
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-marker-unlink-retry-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let workspaceStatus = try XCTUnwrap(
                DebugEditorFindFixture.entryStatus(at: fixture.workspaceURL)
            )
            let workspaceIdentity = DebugEditorFindFixture.identity(
                of: workspaceStatus
            )
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: fixture.identifier,
                in: locations.root
            )
            let rootSentinel = locations.root.appendingPathComponent(
                "root-sentinel"
            )
            try Data("root-sentinel".utf8).write(to: rootSentinel)
            var quarantineURL: URL?
            var markerURL: URL?
            var markerUnlinkCount = 0
            let replacementSentinel = fixture.workspaceURL
                .appendingPathComponent("replacement-sentinel")

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        switch boundary {
                        case let .didQuarantine(_, destination):
                            quarantineURL = destination
                        case let .didUnlinkWorkspaceOwnershipMarker(marker):
                            markerUnlinkCount += 1
                            markerURL = marker
                            XCTAssertFalse(
                                fileManager.fileExists(atPath: marker.path)
                            )
                            let quarantine = try XCTUnwrap(quarantineURL)
                            XCTAssertEqual(
                                marker.deletingLastPathComponent(),
                                quarantine
                            )
                            let quarantineStatus = try XCTUnwrap(
                                DebugEditorFindFixture.entryStatus(
                                    at: quarantine
                                )
                            )
                            XCTAssertEqual(
                                DebugEditorFindFixture.identity(
                                    of: quarantineStatus
                                ),
                                workspaceIdentity
                            )
                            try fileManager.createDirectory(
                                at: fixture.workspaceURL,
                                withIntermediateDirectories: false
                            )
                            try Data("replacement".utf8).write(
                                to: replacementSentinel
                            )
                            throw EditorFindRemovalRaceTestError
                                .afterOwnershipMarkerUnlink
                        default:
                            break
                        }
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterOwnershipMarkerUnlink = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let quarantine = try XCTUnwrap(quarantineURL)
            let marker = try XCTUnwrap(markerURL)
            XCTAssertEqual(markerUnlinkCount, 1)
            XCTAssertTrue(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: marker.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
            XCTAssertEqual(
                try String(contentsOf: replacementSentinel, encoding: .utf8),
                "replacement"
            )
            XCTAssertEqual(
                try String(contentsOf: rootSentinel, encoding: .utf8),
                "root-sentinel"
            )

            try fixture.remove(
                fileManager: fileManager,
                cleanupBoundaryHandler: { boundary in
                    guard case .didUnlinkWorkspaceOwnershipMarker = boundary
                    else { return }
                    XCTFail("A reconciled marker unlink must not be repeated")
                }
            )
            try fixture.remove(fileManager: fileManager)

            XCTAssertEqual(markerUnlinkCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
            XCTAssertEqual(
                try String(contentsOf: replacementSentinel, encoding: .utf8),
                "replacement"
            )
            XCTAssertEqual(
                try String(contentsOf: rootSentinel, encoding: .utf8),
                "root-sentinel"
            )
        }
    }

    final class DebugEditorFindFixtureStaleMarkerRetryTests: XCTestCase {
        func testStaleSweepRetriesAfterOwnershipMarkerUnlinkInSameInvocation() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(
                prefix: "StaleMarkerUnlinkRetry"
            )
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-marker-retry-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: locations.root
            )
            let rootSentinel = locations.root.appendingPathComponent(
                "root-sentinel"
            )
            try Data("root-sentinel".utf8).write(to: rootSentinel)
            let now = Date()
            try makeRemovalRaceEntryExpired(workspaceURL, relativeTo: now)
            fixture = nil
            let replacementSentinel = workspaceURL.appendingPathComponent(
                "replacement-sentinel"
            )
            var quarantineURL: URL?
            var markerURL: URL?
            var markerUnlinkCount = 0

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now,
                cleanupBoundaryHandler: { boundary in
                    switch boundary {
                    case let .didQuarantine(_, destination):
                        quarantineURL = destination
                    case let .didUnlinkWorkspaceOwnershipMarker(marker):
                        markerUnlinkCount += 1
                        markerURL = marker
                        XCTAssertFalse(
                            fileManager.fileExists(atPath: marker.path)
                        )
                        try fileManager.createDirectory(
                            at: workspaceURL,
                            withIntermediateDirectories: false
                        )
                        try Data("replacement".utf8).write(
                            to: replacementSentinel
                        )
                        throw EditorFindRemovalRaceTestError
                            .afterOwnershipMarkerUnlink
                    default:
                        break
                    }
                }
            )

            let quarantine = try XCTUnwrap(quarantineURL)
            let marker = try XCTUnwrap(markerURL)
            XCTAssertEqual(markerUnlinkCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertFalse(fileManager.fileExists(atPath: marker.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
            XCTAssertEqual(
                try String(contentsOf: replacementSentinel, encoding: .utf8),
                "replacement"
            )
            XCTAssertEqual(
                try String(contentsOf: rootSentinel, encoding: .utf8),
                "root-sentinel"
            )
        }

        func testLaterStaleSweepPreservesPostUnlinkMarkerReplacement() throws {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(
                prefix: "StaleMarkerReplacement"
            )
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-marker-replacement-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: identifier,
                in: locations.root
            )
            let rootSentinel = locations.root.appendingPathComponent(
                "root-sentinel"
            )
            try Data("root-sentinel".utf8).write(to: rootSentinel)
            let now = Date()
            try makeRemovalRaceEntryExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var quarantineURL: URL?
            var replacementMarkerURL: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        switch boundary {
                        case let .didQuarantine(_, destination):
                            quarantineURL = destination
                        case let .didUnlinkWorkspaceOwnershipMarker(marker):
                            try Data("replacement-marker".utf8).write(
                                to: marker
                            )
                            replacementMarkerURL = marker
                            throw EditorFindRemovalRaceTestError
                                .afterOwnershipMarkerUnlink
                        default:
                            break
                        }
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterOwnershipMarkerUnlink = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let quarantine = try XCTUnwrap(quarantineURL)
            let marker = try XCTUnwrap(replacementMarkerURL)
            XCTAssertTrue(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
            XCTAssertEqual(
                try String(contentsOf: marker, encoding: .utf8),
                "replacement-marker"
            )

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now
            )

            XCTAssertTrue(fileManager.fileExists(atPath: quarantine.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
            XCTAssertEqual(
                try String(contentsOf: marker, encoding: .utf8),
                "replacement-marker"
            )
            XCTAssertEqual(
                try String(contentsOf: rootSentinel, encoding: .utf8),
                "root-sentinel"
            )
        }
    }

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

    private func makeRemovalRaceLocations(
        prefix: String
    ) throws -> (container: URL, root: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EditorFind\(prefix)-\(UUID().uuidString)",
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

    private func makeRemovalRaceEntryExpired(
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
