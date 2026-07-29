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
    }

    extension DebugEditorFindFixtureTests {
        func testCreatedFixtureCleanupRejectsReplacementDirectory() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-directory-replacement-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let heldOriginal = fixture.workspaceURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "held-original-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.moveItem(at: fixture.workspaceURL, to: heldOriginal)
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
            try fileManager.createDirectory(
                at: fixture.workspaceURL,
                withIntermediateDirectories: false
            )
            let sentinel = fixture.workspaceURL.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)

            XCTAssertThrowsError(try fixture.remove(fileManager: fileManager)) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeCreatedFixture = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(
                try String(contentsOf: sentinel, encoding: .utf8),
                "preserve"
            )

            try fileManager.removeItem(at: fixture.workspaceURL)
            try fileManager.moveItem(at: heldOriginal, to: fixture.workspaceURL)
            try fixture.remove(fileManager: fileManager)
        }

        func testCreatedFixtureCleanupUnlinksNestedSymlinkWithoutTouchingTarget() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-nested-link-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let external = fileManager.temporaryDirectory.appendingPathComponent(
                "EditorFindNestedLinkTarget-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
            let sentinel = external.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)
            try fileManager.createSymbolicLink(
                at: fixture.workspaceURL.appendingPathComponent("external-link"),
                withDestinationURL: external
            )
            defer {
                try? fixture.remove(fileManager: fileManager)
                try? fileManager.removeItem(at: external)
            }

            try fixture.remove(fileManager: fileManager)

            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
        }

        func testFixtureCreationRejectsIdentifiersOutsideItsPrefixAndSafeAlphabet() {
            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(identifier: "other-\(UUID().uuidString)")
            )
            XCTAssertThrowsError(
                try DebugEditorFindFixture.create(identifier: "f9-unsafe/../fixture")
            )
        }

        func testCleanupRequestRequiresExactFixtureIdentifierAndNonemptyToken() {
            XCTAssertTrue(
                DebugEditorFindFixture.cleanupRequestMatches(
                    fixtureIdentifier: "f9-current",
                    cleanupToken: "current-token",
                    request: "quit:f9-current:current-token"
                )
            )
            XCTAssertFalse(
                DebugEditorFindFixture.cleanupRequestMatches(
                    fixtureIdentifier: "f9-current",
                    cleanupToken: "current-token",
                    request: "quit:f9-other:current-token"
                )
            )
            XCTAssertFalse(
                DebugEditorFindFixture.cleanupRequestMatches(
                    fixtureIdentifier: "f9-current",
                    cleanupToken: "current-token",
                    request: "quit:f9-current:other-token"
                )
            )
            XCTAssertFalse(
                DebugEditorFindFixture.cleanupRequestMatches(
                    fixtureIdentifier: "f9-current",
                    cleanupToken: "",
                    request: "quit:f9-current:"
                )
            )
        }

        func testCreatedFixtureCleanupRejectsReplacementRootAndPreservesBothRoots() throws {
            let fileManager = FileManager.default
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-root-replacement-\(UUID().uuidString)",
                fileManager: fileManager
            )
            let fixturesRoot = fixture.workspaceURL.deletingLastPathComponent()
            let rootParent = fixturesRoot.deletingLastPathComponent()
            let heldRoot = rootParent.appendingPathComponent("Held-\(UUID().uuidString)")
            let heldReplacement = rootParent.appendingPathComponent(
                "Replacement-\(UUID().uuidString)"
            )
            defer {
                if fileManager.fileExists(atPath: fixturesRoot.path) {
                    try? fileManager.moveItem(at: fixturesRoot, to: heldReplacement)
                }
                if fileManager.fileExists(atPath: heldRoot.path) {
                    try? fileManager.moveItem(at: heldRoot, to: fixturesRoot)
                }
                try? fixture.remove(fileManager: fileManager)
                try? fileManager.removeItem(at: heldReplacement)
            }

            try fileManager.moveItem(at: fixturesRoot, to: heldRoot)
            try fileManager.createDirectory(
                at: fixturesRoot,
                withIntermediateDirectories: false
            )
            let replacementWorkspace = fixturesRoot.appendingPathComponent(
                fixture.identifier,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: replacementWorkspace,
                withIntermediateDirectories: false
            )
            let sentinel = replacementWorkspace.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)

            XCTAssertThrowsError(try fixture.remove(fileManager: fileManager)) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: heldRoot.appendingPathComponent(fixture.identifier).path
                )
            )
        }

        func testRemoveStaleFixturesPreservesUnleasedCurrentRecentUnrelatedAndSymlink() throws {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFixtureCleanup-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            let current = try makeDirectory(named: "f9-current", under: root)
            let stale = try makeDirectory(named: "f9-stale", under: root)
            let recent = try makeDirectory(named: "f9-recent", under: root)
            let unrelated = try makeDirectory(named: "other-stale", under: root)
            let symlink = root.appendingPathComponent("f9-link")
            try fileManager.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

            let now = Date(timeIntervalSinceReferenceDate: 10000)
            let expired = now.addingTimeInterval(-DebugEditorFindFixture.staleFixtureAge - 1)
            for url in [stale, unrelated] {
                try fileManager.setAttributes(
                    [.modificationDate: expired],
                    ofItemAtPath: url.path
                )
            }
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: recent.path
            )

            try DebugEditorFindFixture.removeStaleFixtures(
                in: root,
                excluding: current.lastPathComponent,
                fileManager: fileManager,
                now: now
            )

            XCTAssertTrue(fileManager.fileExists(atPath: current.path))
            XCTAssertTrue(
                fileManager.fileExists(atPath: stale.path),
                "A legacy directory without a lease has no provable ownership"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: recent.path))
            XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
            XCTAssertTrue(fileManager.fileExists(atPath: symlink.path))
        }

        func testRemoveStaleFixturesRejectsSymlinkRootWithoutTouchingTarget() throws {
            let fileManager = FileManager.default
            let container = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindFixtureRootLink-\(UUID().uuidString)",
                    isDirectory: true
                )
            let target = container.appendingPathComponent("target", isDirectory: true)
            let rootLink = container.appendingPathComponent("fixtures", isDirectory: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: container) }

            let stale = try makeDirectory(named: "f9-stale", under: target)
            try fileManager.createSymbolicLink(at: rootLink, withDestinationURL: target)

            XCTAssertThrowsError(
                try DebugEditorFindFixture.removeStaleFixtures(
                    in: rootLink,
                    excluding: "f9-current",
                    fileManager: fileManager,
                    now: Date.distantFuture
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError.unsafeFixturesRoot = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: stale.path))
            XCTAssertTrue(fileManager.fileExists(atPath: rootLink.path))
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
