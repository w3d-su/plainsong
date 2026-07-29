#if DEBUG
    @testable import Plainsong
    import XCTest

    final class DebugEditorFindFixtureCleanupSafetyTests: XCTestCase {
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
    }

    final class DebugEditorFindFixtureIdentityTests: XCTestCase {
        func testCreatedFixtureCleanupRejectsReplacementRootAndPreservesBothRoots() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindRootReplacement-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: testContainer,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let isolatedRoot = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-root-replacement-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: isolatedRoot
            )
            let fixturesRoot = fixture.workspaceURL.deletingLastPathComponent()
            let heldRoot = testContainer.appendingPathComponent("Held-\(UUID().uuidString)")
            let heldReplacement = testContainer.appendingPathComponent(
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

        func testCleanupDoesNotVerifyRemovalWhenCapturedWorkspaceIsSwappedDuringDelete() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindWorkspaceSwap-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: testContainer,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let isolatedRoot = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-workspace-swap-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: isolatedRoot
            )
            let heldWorkspace = isolatedRoot.appendingPathComponent(
                "held-workspace-\(UUID().uuidString)",
                isDirectory: true
            )

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    workspaceRemover: { workspaceURL in
                        try fileManager.moveItem(
                            at: workspaceURL,
                            to: heldWorkspace
                        )
                        try fileManager.createDirectory(
                            at: workspaceURL,
                            withIntermediateDirectories: false
                        )
                        try fileManager.removeItem(at: workspaceURL)
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: heldWorkspace.path))
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: DebugEditorFindFixture.ownershipLeaseURL(
                        for: fixture.identifier,
                        in: isolatedRoot
                    ).path
                )
            )

            try fileManager.moveItem(
                at: heldWorkspace,
                to: fixture.workspaceURL
            )
            try fixture.remove(fileManager: fileManager)
            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
        }

        func testCleanupRejectsRenamedCapturedDirectoryAfterItsMarkerIsUnlinked() throws {
            let fileManager = FileManager.default
            let testContainer = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "EditorFindWorkspaceDescriptor-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: testContainer,
                withIntermediateDirectories: false
            )
            defer { try? fileManager.removeItem(at: testContainer) }
            let isolatedRoot = testContainer.appendingPathComponent(
                "PlainsongEditorFindUITests",
                isDirectory: true
            )
            let fixture = try DebugEditorFindFixture.create(
                identifier: "f9-workspace-descriptor-\(UUID().uuidString)",
                fileManager: fileManager,
                fixturesRootOverride: isolatedRoot
            )
            let heldWorkspace = isolatedRoot.appendingPathComponent(
                "held-empty-workspace-\(UUID().uuidString)",
                isDirectory: true
            )

            XCTAssertThrowsError(
                try fixture.remove(
                    fileManager: fileManager,
                    workspaceRemover: { workspaceURL in
                        try fileManager.moveItem(
                            at: workspaceURL,
                            to: heldWorkspace
                        )
                        for child in try fileManager.contentsOfDirectory(
                            at: heldWorkspace,
                            includingPropertiesForKeys: nil,
                            options: []
                        ) {
                            try fileManager.removeItem(at: child)
                        }
                    }
                )
            ) { error in
                guard case DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete = error
                else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(fileManager.fileExists(atPath: heldWorkspace.path))
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: DebugEditorFindFixture.ownershipLeaseURL(
                        for: fixture.identifier,
                        in: isolatedRoot
                    ).path
                )
            )

            try fileManager.moveItem(
                at: heldWorkspace,
                to: fixture.workspaceURL
            )
            try fixture.remove(fileManager: fileManager)
            XCTAssertFalse(fileManager.fileExists(atPath: fixture.workspaceURL.path))
        }
    }
#endif
