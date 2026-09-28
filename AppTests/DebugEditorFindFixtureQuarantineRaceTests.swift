#if DEBUG
    @testable import Plainsong
    import XCTest

    private enum InjectedFailure: Error {
        case afterQuarantine
        case afterRemoval
    }

    final class EditorFindQuarantineLiveRaceTests: XCTestCase {
        func testLiveCleanupPreservesReplacementInsertedBeforeQuarantine() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "LiveWillQuarantine")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-will-quarantine-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let heldExact = heldExactURL(in: locations.container)
            let leaseURL = leaseURL(for: fixture.identifier, in: locations.root)
            var quarantinedReplacement: URL?
            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .willQuarantine(source, destination) = boundary
                        else { return }
                        try fileManager.moveItem(at: source, to: heldExact)
                        try createSentinelDirectory(at: source)
                        quarantinedReplacement = destination
                    }
                )
            ) { assertUnsafeCreatedFixture($0) }

            let quarantineURL = try XCTUnwrap(quarantinedReplacement)
            try assertSentinelSurvives(in: quarantineURL)
            XCTAssertTrue(fileManager.fileExists(atPath: heldExact.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testLiveCleanupPreservesPublishedReplacementInsertedAfterQuarantine() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "LiveDidQuarantine")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-did-quarantine-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let leaseURL = leaseURL(for: fixture.identifier, in: locations.root)
            var exactQuarantine: URL?

            try fixture.remove(
                fileManager: fileManager,
                cleanupBoundaryHandler: { boundary in
                    guard case let .didQuarantine(source, destination) = boundary
                    else { return }
                    exactQuarantine = destination
                    try createSentinelDirectory(at: source)
                }
            )

            try assertSentinelSurvives(in: fixture.workspaceURL)
            let quarantineURL = try XCTUnwrap(exactQuarantine)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantineURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testLiveCleanupPreservesReplacementAtFinalRemovalBoundary() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "LiveWillRemove")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-will-remove-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let heldExact = heldExactURL(in: locations.container)
            let leaseURL = leaseURL(for: fixture.identifier, in: locations.root)
            var replacementURL: URL?
            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didValidateQuarantineForRemoval(
                            quarantineURL
                        ) = boundary
                        else { return }
                        try fileManager.moveItem(at: quarantineURL, to: heldExact)
                        try createSentinelDirectory(at: quarantineURL)
                        replacementURL = quarantineURL
                    }
                )
            ) { assertUnsafeCreatedFixture($0) }

            try assertSentinelSurvives(in: XCTUnwrap(replacementURL))
            XCTAssertTrue(fileManager.fileExists(atPath: heldExact.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testLiveCleanupRetryCompletesAfterRemoverDeletesThenThrows() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "LiveRemovalRetry")
            defer { try? fileManager.removeItem(at: locations.container) }
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-live-removal-retry-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: locations.root
            )
            let leaseURL = leaseURL(for: fixture.identifier, in: locations.root)
            var removerCallCount = 0
            var removedQuarantine: URL?

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    workspaceRemover: { quarantineURL in
                        removerCallCount += 1
                        removedQuarantine = quarantineURL
                        try fileManager.removeItem(at: quarantineURL)
                        throw InjectedFailure.afterRemoval
                    }
                )
            ) { error in
                guard case InjectedFailure.afterRemoval = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(removerCallCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
            let quarantineURL = try XCTUnwrap(removedQuarantine)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantineURL.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))

            try fixture.remove(
                fileManager: fileManager,
                workspaceRemover: { _ in
                    removerCallCount += 1
                    XCTFail("A verified remove-then-throw retry must not remove again")
                }
            )
            try fixture.remove(fileManager: fileManager)

            XCTAssertEqual(removerCallCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }
    }

    final class EditorFindQuarantineStaleRaceTests: XCTestCase {
        func testStaleSweepPreservesReplacementInsertedBeforeQuarantine() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "StaleWillQuarantine")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-will-quarantine-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = leaseURL(for: identifier, in: locations.root)
            let heldExact = heldExactURL(in: locations.container)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var quarantinedReplacement: URL?

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now,
                cleanupBoundaryHandler: { boundary in
                    guard case let .willQuarantine(source, destination) = boundary
                    else { return }
                    try fileManager.moveItem(at: source, to: heldExact)
                    try createSentinelDirectory(at: source)
                    quarantinedReplacement = destination
                }
            )

            let quarantineURL = try XCTUnwrap(quarantinedReplacement)
            try assertSentinelSurvives(in: quarantineURL)
            XCTAssertTrue(fileManager.fileExists(atPath: heldExact.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testStaleSweepPreservesPublishedReplacementInsertedAfterQuarantine() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "StaleDidQuarantine")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-did-quarantine-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = leaseURL(for: identifier, in: locations.root)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var exactQuarantine: URL?

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now,
                cleanupBoundaryHandler: { boundary in
                    guard case let .didQuarantine(source, destination) = boundary
                    else { return }
                    exactQuarantine = destination
                    try createSentinelDirectory(at: source)
                }
            )

            try assertSentinelSurvives(in: workspaceURL)
            let quarantineURL = try XCTUnwrap(exactQuarantine)
            XCTAssertFalse(fileManager.fileExists(atPath: quarantineURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testStaleSweepPreservesReplacementAtFinalRemovalBoundary() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "StaleWillRemove")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-will-remove-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = leaseURL(for: identifier, in: locations.root)
            let heldExact = heldExactURL(in: locations.container)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var replacementURL: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didValidateQuarantineForRemoval(
                            quarantineURL
                        ) = boundary
                        else { return }
                        try fileManager.moveItem(at: quarantineURL, to: heldExact)
                        try createSentinelDirectory(at: quarantineURL)
                        replacementURL = quarantineURL
                    }
                )
            ) { assertUnsafeCreatedFixture($0) }

            try assertSentinelSurvives(in: XCTUnwrap(replacementURL))
            XCTAssertTrue(fileManager.fileExists(atPath: heldExact.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))
        }

        func testStaleSweepRecoversExactQuarantineAfterInterruptedCleanup() throws {
            let fileManager = FileManager.default
            let locations = try makeIsolatedLocations(prefix: "StaleQuarantineRecovery")
            defer { try? fileManager.removeItem(at: locations.container) }
            let identifier = "f9-stale-q-recovery-\(UUID().uuidString)"
            var fixture: DebugEditorFindFixture.CreatedFixture? =
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager,
                    fixturesRootOverride: locations.root
                )
            let workspaceURL = try XCTUnwrap(fixture?.workspaceURL)
            let leaseURL = leaseURL(for: identifier, in: locations.root)
            let now = Date()
            try makeExpired(workspaceURL, relativeTo: now)
            fixture = nil
            var exactQuarantine: URL?

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: locations.root,
                    excluding: "f9-current-\(UUID().uuidString)",
                    fileManager: fileManager,
                    now: now,
                    cleanupBoundaryHandler: { boundary in
                        guard case let .didQuarantine(_, destination) = boundary
                        else { return }
                        exactQuarantine = destination
                        throw InjectedFailure.afterQuarantine
                    }
                )
            ) { error in
                guard case InjectedFailure.afterQuarantine = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let quarantineURL = try XCTUnwrap(exactQuarantine)
            XCTAssertTrue(fileManager.fileExists(atPath: quarantineURL.path))
            XCTAssertTrue(fileManager.fileExists(atPath: leaseURL.path))

            try DebugEditorFindFixture.removeStaleFixtures(
                in: locations.root,
                excluding: "f9-current-\(UUID().uuidString)",
                fileManager: fileManager,
                now: now
            )

            XCTAssertFalse(fileManager.fileExists(atPath: quarantineURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: leaseURL.path))
        }
    }

    private func makeIsolatedLocations(
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

    private func leaseURL(for identifier: String, in root: URL) -> URL {
        DebugEditorFindFixture.ownershipLeaseURL(
            for: identifier,
            in: root
        )
    }

    private func heldExactURL(in container: URL) -> URL {
        container.appendingPathComponent("held-exact", isDirectory: true)
    }

    private func createSentinelDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try writeSentinel(in: url)
    }

    private func writeSentinel(in directory: URL) throws {
        try Data("preserve".utf8).write(
            to: directory.appendingPathComponent("replacement-sentinel")
        )
    }

    private func assertSentinelSurvives(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(
                    "replacement-sentinel"
                ),
                encoding: .utf8
            ),
            "preserve",
            file: file,
            line: line
        )
    }

    private func assertUnsafeCreatedFixture(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case DebugEditorFindFixture.FixtureError.unsafeCreatedFixture = error else {
            return XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeExpired(_ url: URL, relativeTo now: Date) throws {
        let expiration = now.addingTimeInterval(
            -DebugEditorFindFixture.staleFixtureAge - 1
        )
        try FileManager.default.setAttributes(
            [.modificationDate: expiration],
            ofItemAtPath: url.path
        )
    }
#endif
