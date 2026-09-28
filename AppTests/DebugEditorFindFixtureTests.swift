#if DEBUG
    @testable import Plainsong
    import XCTest

    private final class FixtureCreationResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [
            Result<DebugEditorFindFixture.CreatedFixture, Error>
        ] = []

        func append(
            _ value: Result<DebugEditorFindFixture.CreatedFixture, Error>
        ) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [
            Result<DebugEditorFindFixture.CreatedFixture, Error>
        ] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    final class DebugEditorFindFixtureTests: XCTestCase {
        @MainActor
        func testAppLaunchFactoryUsesIsolatedPersistenceForEditorFindFixture() throws {
            let fixtureDefaults = try XCTUnwrap(
                UserDefaults(suiteName: DebugWorkspaceSearchFixture.userDefaultsSuiteName)
            )
            defer { DebugWorkspaceSearchFixture.clearIsolatedDefaults(fixtureDefaults) }

            let appState = makePlainsongAppState(environment: [
                DebugEditorFindFixture.environmentKey: "f9-launch-path",
            ])

            XCTAssertTrue(appState.lastOpenedFileStore is DebugLastOpenedFileStore)
            XCTAssertTrue(appState.recentItemStore is DebugRecentItemStore)
            XCTAssertFalse(appState.shouldRestoreLastOpenedFile)
            XCTAssertTrue(appState.recentItemURLs.isEmpty)
            XCTAssertNil(appState.currentDocument.fileURL)
        }

        func testFixtureProvidesExactAndOverflowingProductionQueries() throws {
            let fileManager = FileManager.default
            let identifier = "f9-unit-\(UUID().uuidString)"
            let fixture = try DebugEditorFindFixture.create(
                identifier: identifier,
                fileManager: fileManager
            )
            defer { try? fixture.remove(fileManager: fileManager) }

            let source = try String(
                contentsOf: fixture.workspaceURL.appendingPathComponent("editor-find.md"),
                encoding: .utf8
            )
            XCTAssertEqual(source.components(separatedBy: "needle").count - 1, 3)
            XCTAssertEqual(source.components(separatedBy: "x").count - 1, 10001)
            XCTAssertEqual(source.components(separatedBy: "caseprobe").count - 1, 1)
            XCTAssertEqual(source.components(separatedBy: "CASEPROBE").count - 1, 1)
            XCTAssertEqual(source.components(separatedBy: "wordprobe").count - 1, 3)
        }

        func testFixtureCreationRejectsOccupiedIdentifierWithoutDeletingIt() throws {
            let fileManager = FileManager.default
            let identifier = "f9-occupied-\(UUID().uuidString)"
            let fixture = try DebugEditorFindFixture.create(
                identifier: identifier,
                fileManager: fileManager
            )
            defer { try? fixture.remove(fileManager: fileManager) }
            let sentinel = fixture.workspaceURL.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)

            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(
                    identifier: identifier,
                    fileManager: fileManager
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.fixtureAlreadyExists = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(
                try String(contentsOf: sentinel, encoding: .utf8),
                "preserve"
            )
        }

        func testConcurrentSameIdentifierCreationCannotDeleteWinner() throws {
            let identifier = "f9-concurrent-\(UUID().uuidString)"
            let results = FixtureCreationResults()

            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                results.append(
                    Result {
                        try DebugEditorFindFixture.create(
                            identifier: identifier
                        )
                    }
                )
            }

            let snapshot = results.snapshot()
            let created = snapshot.compactMap { try? $0.get() }
            let fixture = try XCTUnwrap(created.first)
            defer { try? fixture.remove() }
            XCTAssertEqual(created.count, 1)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.workspaceURL.path
                )
            )

            for result in snapshot where (try? result.get()) == nil {
                XCTAssertThrowsError(try result.get()) { error in
                    guard case DebugEditorFindFixture.FixtureError
                        .fixtureAlreadyExists = error
                    else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }

        func testCreatedFixtureCleanupRemovesOnlyItsExactDirectoryAndIsIdempotent() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-cleanup-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let root = fixture.workspaceURL.deletingLastPathComponent()
            let sibling = try makeDirectory(
                named: "f9-sibling-\(UUID().uuidString)",
                under: root
            )
            let unrelated = try makeDirectory(
                named: "unrelated-\(UUID().uuidString)",
                under: root
            )
            defer {
                try? fileManager.removeItem(at: sibling)
                try? fileManager.removeItem(at: unrelated)
            }

            try fixture.remove(fileManager: fileManager)
            try fixture.remove(fileManager: fileManager)

            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: DebugEditorFindFixture.ownershipLeaseURL(
                        for: fixture.identifier,
                        in: root
                    ).path
                )
            )
            XCTAssertTrue(fileManager.fileExists(atPath: sibling.path))
            XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
        }

        func testCreatedFixtureCleanupRejectsReplacementSymlinkAndPreservesTarget() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-link-replacement-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let external = fileManager.temporaryDirectory.appendingPathComponent(
                "EditorFindFixtureExternal-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)
            let heldOriginal = fixture.workspaceURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "held-original-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.moveItem(at: fixture.workspaceURL, to: heldOriginal)
            try fileManager.createSymbolicLink(
                at: fixture.workspaceURL,
                withDestinationURL: external
            )
            defer {
                try? fileManager.removeItem(at: fixture.workspaceURL)
                if fileManager.fileExists(atPath: heldOriginal.path) {
                    try? fileManager.moveItem(
                        at: heldOriginal,
                        to: fixture.workspaceURL
                    )
                }
                try? fixture.remove(fileManager: fileManager)
                try? fileManager.removeItem(at: external)
            }

            XCTAssertThrowsError(try fixture.remove(fileManager: fileManager)) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeCreatedFixture = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: fixture.workspaceURL.path))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")

            try fileManager.removeItem(at: fixture.workspaceURL)
            try fileManager.moveItem(at: heldOriginal, to: fixture.workspaceURL)
            try fixture.remove(fileManager: fileManager)
        }

        func testCreatedFixtureCleanupRejectsReplacementRegularFile() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-file-replacement-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let heldOriginal = fixture.workspaceURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "held-original-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.moveItem(at: fixture.workspaceURL, to: heldOriginal)
            try Data("preserve".utf8).write(to: fixture.workspaceURL)
            defer {
                try? fileManager.removeItem(at: fixture.workspaceURL)
                if fileManager.fileExists(atPath: heldOriginal.path) {
                    try? fileManager.moveItem(
                        at: heldOriginal,
                        to: fixture.workspaceURL
                    )
                }
                try? fixture.remove(fileManager: fileManager)
            }

            XCTAssertThrowsError(try fixture.remove(fileManager: fileManager)) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeCreatedFixture = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(
                try String(contentsOf: fixture.workspaceURL, encoding: .utf8),
                "preserve"
            )

            try fileManager.removeItem(at: fixture.workspaceURL)
            try fileManager.moveItem(at: heldOriginal, to: fixture.workspaceURL)
            try fixture.remove(fileManager: fileManager)
        }

        private func makeDirectory(named name: String, under root: URL) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
            return url
        }
    }
#endif
