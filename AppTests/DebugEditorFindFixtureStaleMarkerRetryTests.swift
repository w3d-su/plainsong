#if DEBUG
    @testable import Plainsong
    import XCTest

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
            try makeRemovalRaceEntryExpired(quarantine, relativeTo: now)
            var rejectedBindingURLs = [URL]()
            var reachedRemoval = false

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now,
                cleanupBoundaryHandler: { boundary in
                    switch boundary {
                    case let .didRejectStaleWorkspaceBinding(candidate):
                        rejectedBindingURLs.append(candidate.standardizedFileURL)
                    case .willRemoveQuarantine:
                        reachedRemoval = true
                    default:
                        break
                    }
                }
            )

            XCTAssertEqual(
                rejectedBindingURLs,
                [quarantine.standardizedFileURL]
            )
            XCTAssertFalse(reachedRemoval)
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
#endif
