#if DEBUG
    @testable import Plainsong
    import XCTest

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

        func testLiveCleanupRetryAfterExactQuarantineRemovalPreservesPublishedReplacement()
            throws
        {
            let fileManager = FileManager.default
            let locations = try makeRemovalRaceLocations(
                prefix: "PostRmdirPublishedReplacement"
            )
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-post-rmdir-retry-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let leaseURL = DebugEditorFindFixture.ownershipLeaseURL(
                for: fixture.identifier,
                in: locations.root
            )
            let rootSentinel = locations.root.appendingPathComponent(
                "root-sentinel"
            )
            try Data("root-sentinel".utf8).write(to: rootSentinel)
            let replacementSentinel = fixture.workspaceURL
                .appendingPathComponent("replacement-sentinel")
            var quarantineURL: URL?
            var removerCallCount = 0

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    workspaceRemover: { quarantine in
                        removerCallCount += 1
                        quarantineURL = quarantine
                        try fileManager.removeItem(at: quarantine)
                        try fileManager.createDirectory(
                            at: fixture.workspaceURL,
                            withIntermediateDirectories: false
                        )
                        try Data("replacement".utf8).write(
                            to: replacementSentinel
                        )
                        throw EditorFindRemovalRaceTestError
                            .afterExactWorkspaceRemoval
                    }
                )
            ) { error in
                guard case EditorFindRemovalRaceTestError
                    .afterExactWorkspaceRemoval = error
                else { return XCTFail("Unexpected error: \(error)") }
            }

            let quarantine = try XCTUnwrap(quarantineURL)
            XCTAssertEqual(removerCallCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
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
                workspaceRemover: { _ in
                    removerCallCount += 1
                    XCTFail("Verified exact removal must not invoke the remover again")
                    throw EditorFindRemovalRaceTestError
                        .afterExactWorkspaceRemoval
                }
            )
            try fixture.remove(fileManager: fileManager)

            XCTAssertEqual(removerCallCount, 1)
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
#endif
