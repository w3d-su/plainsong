// swiftlint:disable file_length type_body_length
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class AppStateWorkspaceDataIntegrityTests: XCTestCase {
    func testDefaultRecoveryStoresAreIsolatedPerAppStateUnderXCTest() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateWorkspaceDataIntegrityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let textRecord = WorkspaceMutationTextRecoveryRecord(
            originalURL: rootURL.appendingPathComponent("draft.md"),
            fileKind: .markdown,
            source: "Recovered",
            revision: 1,
            reason: .trash
        )
        let operationRecord = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(),
            rootBookmarkData: Data("test-root".utf8),
            rootDisplayURL: rootURL,
            rootExpectation: .init(device: 1, inode: 2, kind: .directory),
            payload: .creation(.init(
                destinationRelativePath: "draft.md",
                kind: .file,
                isPlanned: true,
                expectedCreatedItem: nil,
                reason: .unreadable,
                recoveryState: .none,
                recoveryExpectation: nil,
                publicationSourceRelativePath: nil,
                actualPublishedExpectation: nil
            )),
            textRecoveryRecords: [textRecord]
        )
        let first = AppState(shouldRestoreLastOpenedFile: false)

        try first.workspaceMutationOperationRecoveryStore.upsert(operationRecord)
        try first.workspaceMutationTextRecoveryStore.upsert(textRecord)
        XCTAssertEqual(
            try first.workspaceMutationOperationRecoveryStore.load(),
            [operationRecord]
        )
        XCTAssertEqual(
            try first.workspaceMutationTextRecoveryStore.load(),
            [textRecord]
        )

        let second = AppState(shouldRestoreLastOpenedFile: false)
        XCTAssertTrue(try second.workspaceMutationOperationRecoveryStore.load().isEmpty)
        XCTAssertTrue(try second.workspaceMutationTextRecoveryStore.load().isEmpty)
    }

    func testRenamePersistsWriteAheadIntentBeforeFilesystemMutation() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        var observedWriteAhead = false
        operationStore.onUpsert = { record in
            guard !observedWriteAhead,
                  case let .relocation(relocation) = record.payload,
                  relocation.sessionCommitPhase == .pendingSessionCommit
            else {
                return
            }
            observedWriteAhead = true
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
            XCTAssertEqual(record.textRecoveryRecords.first?.source, "Original")
        }

        try fixture.appState.renameWorkspaceItem(
            at: source,
            to: "renamed.md",
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        XCTAssertTrue(observedWriteAhead)
        XCTAssertTrue(operationStore.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.fileURL.path))
    }

    func testDirtyRelocationJournalFailurePersistsStandaloneBeforeQuarantine() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            recoveryStore: textStore
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        fixture.appState.applyDocumentText(
            "Newest editor text",
            to: fixture.appState.currentDocument
        )
        operationStore.upsertError = TestWorkspaceMutationRecoveryStoreError.failed

        XCTAssertThrowsError(
            try fixture.appState.renameWorkspaceItem(
                at: source,
                to: "renamed.md",
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        )

        XCTAssertTrue(operationStore.records.isEmpty)
        let durableText = try XCTUnwrap(textStore.records.values.first)
        XCTAssertEqual(durableText.source, "Newest editor text")
        XCTAssertEqual(durableText.originalURL, source.fileURL)
        XCTAssertEqual(
            try String(contentsOf: source.fileURL, encoding: .utf8),
            "Original"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("renamed.md").path
        ))

        let relaunched = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        relaunched.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(relaunched.currentDocument.text, "Newest editor text")
        XCTAssertTrue(relaunched.currentDocument.isDirty)
        XCTAssertEqual(relaunched.currentDocument.fileURL, source.fileURL)
    }

    func testDirtyRelocationBundleSurvivesStandaloneFailureAndImmediateRestart() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.upsertError = TestWorkspaceMutationRecoveryStoreError.failed
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            recoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        fixture.appState.applyDocumentText(
            "Newest bundled text",
            to: fixture.appState.currentDocument
        )

        XCTAssertThrowsError(
            try fixture.appState.renameWorkspaceItem(
                at: source,
                to: "renamed.md",
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        )

        XCTAssertTrue(textStore.records.isEmpty)
        let durableOperation = try XCTUnwrap(operationStore.records.values.first)
        XCTAssertEqual(
            durableOperation.textRecoveryRecords.first?.source,
            "Newest bundled text"
        )
        operationStore.removeError = nil

        let relaunched = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        relaunched.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(relaunched.currentDocument.text, "Newest bundled text")
        XCTAssertTrue(relaunched.currentDocument.isDirty)
    }

    func testCommittedRelocationPhaseRekeysBundledTextBeforeSessionCommit() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        var bundledURLAtCommittedPhase: URL?
        var sessionURLAtCommittedPhase: URL?
        operationStore.onUpsert = { record in
            guard bundledURLAtCommittedPhase == nil,
                  case let .relocation(relocation) = record.payload,
                  relocation.sessionCommitPhase == .committedCleanup
            else {
                return
            }
            bundledURLAtCommittedPhase = record.textRecoveryRecords.first?.originalURL
            sessionURLAtCommittedPhase = fixture.appState.currentDocument.fileURL
        }

        try fixture.appState.renameWorkspaceItem(
            at: source,
            to: "renamed.md",
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        XCTAssertEqual(bundledURLAtCommittedPhase, destination.fileURL)
        XCTAssertEqual(sessionURLAtCommittedPhase, source.fileURL)
        XCTAssertEqual(fixture.appState.currentDocument.fileURL, destination.fileURL)
    }

    func testRenameDirtyCurrentSessionRetargetsRetainedAuthorityWithoutRecreatingOldPath() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let session = fixture.appState.currentDocument
        let oldLocation = try fixture.location("post.md")
        let newLocation = try fixture.location("renamed.md")
        let expectation = try fixture.expectation("post.md")
        fixture.appState.applyDocumentText("Changed", to: session)

        try fixture.appState.renameWorkspaceItem(
            at: oldLocation,
            to: "renamed.md",
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        XCTAssertEqual(fixture.appState.sessionStateURL(for: session), newLocation.fileURL)
        XCTAssertEqual(session.fileURL, newLocation.fileURL)
        XCTAssertTrue(session.isDirty)
        XCTAssertNil(fixture.appState.sessionCache[oldLocation.fileURL])
        XCTAssertTrue(fixture.appState.sessionCache[newLocation.fileURL] === session)
        XCTAssertEqual(
            fixture.appState.anchoredSessionFileBinding(for: session)?.location,
            newLocation
        )
        XCTAssertNil(fixture.appState.sessionPolicy.dirtyState(for: oldLocation.fileURL))
        XCTAssertEqual(
            fixture.appState.sessionPolicy.dirtyState(for: newLocation.fileURL),
            true
        )
        XCTAssertNotNil(fixture.appState.autosaveTask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLocation.fileURL.path))

        try fixture.appState.save(session: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLocation.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: newLocation.fileURL, encoding: .utf8),
            "Changed"
        )
    }

    func testMovingDirectoryRetargetsCachedRetiredAndEditorBoundDescendants() throws {
        let fixture = try makeFixture(
            files: [
                "drafts/current.md": "Current",
                "drafts/cached.md": "Cached",
                "drafts/retired.md": "Retired",
                "drafts/editor.md": "Editor",
                "drafts-copy/sibling.md": "Sibling",
                "outside.md": "Outside",
            ],
            directories: ["drafts", "drafts-copy", "archive"],
            currentPath: "drafts/current.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let cached = try fixture.installSession(path: "drafts/cached.md", storage: .cached)
        let retired = try fixture.installSession(path: "drafts/retired.md", storage: .retired)
        let editorOnly = try fixture.installSession(path: "drafts/editor.md", storage: .cached)
        let outside = try fixture.installSession(path: "outside.md", storage: .cached)
        let prefixSibling = try fixture.installSession(
            path: "drafts-copy/sibling.md",
            storage: .cached
        )
        let editorBinding = appState.editorDocumentBinding(for: editorOnly)
        let installation = EditorDocumentBindingInstallation(
            bindingID: editorBinding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        editorBinding.onLifecycle(.installed(installation))
        let editorOldURL = try XCTUnwrap(appState.sessionStateURL(for: editorOnly))
        appState.sessionCache[editorOldURL] = nil
        appState.applyDocumentText("Cached changed", to: cached)
        appState.applyDocumentText("Retired changed", to: retired)
        let expectation = try fixture.expectation("drafts")

        try appState.moveWorkspaceItem(
            at: fixture.location("drafts"),
            toDirectoryRelativePath: "archive",
            expecting: expectation,
            sourceParentExpectation: fixture.parentExpectation("drafts"),
            destinationParentExpectation: fixture.expectation("archive")
        )

        let expected: [(DocumentSession, String)] = [
            (appState.currentDocument, "archive/drafts/current.md"),
            (cached, "archive/drafts/cached.md"),
            (retired, "archive/drafts/retired.md"),
            (editorOnly, "archive/drafts/editor.md"),
        ]
        for (session, path) in expected {
            let destination = try fixture.location(path)
            XCTAssertEqual(session.fileURL, destination.fileURL)
            XCTAssertEqual(appState.sessionStateURL(for: session), destination.fileURL)
            XCTAssertEqual(
                appState.anchoredSessionFileBinding(for: session)?.location,
                destination
            )
        }
        let cachedDestination = try fixture.location("archive/drafts/cached.md").fileURL
        let retiredDestination = try fixture.location("archive/drafts/retired.md").fileURL
        XCTAssertTrue(appState.sessionCache[cachedDestination] === cached)
        XCTAssertTrue(
            appState.retiredEditorDocumentSessions[retiredDestination]?.session === retired
        )
        XCTAssertTrue(appState.editorBindingInstallations[installation] === editorOnly)
        XCTAssertTrue(appState.editorDocumentBindingSessions[editorBinding.id] === editorOnly)
        XCTAssertNil(appState.editorWriterInstallations[ObjectIdentifier(editorOnly)])
        XCTAssertEqual(appState.sessionStateURL(for: outside), try fixture.location("outside.md").fileURL)
        XCTAssertEqual(
            appState.sessionStateURL(for: prefixSibling),
            try fixture.location("drafts-copy/sibling.md").fileURL
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.url("drafts-copy/sibling.md"), encoding: .utf8),
            "Sibling"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts").path))
    }

    func testStaleSnapshotExpectationRefusesReplacementThroughNodeMutation() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let oldLocation = try fixture.location("post.md")
        let expectedIdentity = try fixture.expectation("post.md").identity
        let replacementURL = fixture.url("replacement.md")
        try "Replacement".write(to: replacementURL, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: oldLocation.fileURL)
        try FileManager.default.moveItem(at: replacementURL, to: oldLocation.fileURL)
        XCTAssertNotEqual(try fixture.expectation("post.md").identity, expectedIdentity)

        appState.renameWorkspaceItem(id: "file:post.md", to: "renamed.md")

        XCTAssertEqual(
            try String(contentsOf: oldLocation.fileURL, encoding: .utf8),
            "Replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("renamed.md").path))
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(appState.sessionStateURL(for: session), oldLocation.fileURL)
        XCTAssertTrue(appState.sessionCache[oldLocation.fileURL] === session)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.identity,
            expectedIdentity
        )
        XCTAssertNotNil(appState.presentedError)
    }

    func testStaleDestinationDirectoryExpectationRefusesMoveThroughNodeMutation() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            directories: ["archive"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let sourceURL = fixture.url("post.md")
        let destinationURL = fixture.url("archive/post.md")
        try FileManager.default.moveItem(
            at: fixture.url("archive"),
            to: fixture.url("retained-archive")
        )
        try FileManager.default.createDirectory(
            at: fixture.url("archive"),
            withIntermediateDirectories: false
        )

        appState.moveWorkspaceItem(
            id: "file:post.md",
            toDirectoryID: "directory:archive"
        )

        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertNotNil(appState.presentedError)
    }

    func testHardLinkedTreeNodeRenameMutatesTheSelectedPathOnly() throws {
        let fixture = try makeFixture(
            files: ["first.md": "Shared"],
            currentPath: "first.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        try FileManager.default.linkItem(
            at: fixture.url("first.md"),
            to: fixture.url("second.md")
        )
        let expectation = try fixture.expectation("first.md")
        let snapshot = WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "first.md",
                kind: .markdown,
                identity: "shared-inode",
                contentModificationDate: nil,
                mutationExpectation: expectation
            ),
            WorkspaceFileSnapshot.Entry(
                relativePath: "second.md",
                kind: .markdown,
                identity: "shared-inode",
                contentModificationDate: nil,
                mutationExpectation: expectation
            ),
        ])
        appState.workspaceSnapshot = snapshot
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: snapshot,
            options: .init(showAllFiles: true)
        )
        let secondNode = try XCTUnwrap(
            appState.workspaceTree?.root.children.first(where: {
                $0.relativePath == "second.md"
            })
        )

        appState.renameWorkspaceItem(id: secondNode.id, to: "renamed.md")

        XCTAssertEqual(
            try String(contentsOf: fixture.url("first.md"), encoding: .utf8),
            "Shared"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("second.md").path))
        XCTAssertEqual(
            try String(contentsOf: fixture.url("renamed.md"), encoding: .utf8),
            "Shared"
        )
        XCTAssertNil(appState.presentedError)
    }

    func testDestinationSessionStateCollisionLeavesFilesystemAndAllSessionKeysUnchanged() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Source",
                "renamed.md": "Destination",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = appState.currentDocument
        let destination = try fixture.installSession(path: "renamed.md", storage: .cached)
        let sourceLocation = try fixture.location("post.md")
        let destinationLocation = try fixture.location("renamed.md")
        let sourceBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: source))
        let destinationBinding = try XCTUnwrap(
            appState.anchoredSessionFileBinding(for: destination)
        )
        try FileManager.default.removeItem(at: destinationLocation.fileURL)

        XCTAssertThrowsError(
            try appState.renameWorkspaceItem(
                at: sourceLocation,
                to: "renamed.md",
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        )

        XCTAssertEqual(
            try String(contentsOf: sourceLocation.fileURL, encoding: .utf8),
            "Source"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationLocation.fileURL.path))
        XCTAssertEqual(appState.sessionStateURL(for: source), sourceLocation.fileURL)
        XCTAssertEqual(appState.sessionStateURL(for: destination), destinationLocation.fileURL)
        XCTAssertTrue(appState.sessionCache[sourceLocation.fileURL] === source)
        XCTAssertTrue(appState.sessionCache[destinationLocation.fileURL] === destination)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: source), sourceBinding)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: destination), destinationBinding)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: sourceLocation.fileURL), false)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: destinationLocation.fileURL), false)
        XCTAssertTrue(appState.workspaceMutationWriteFences.isEmpty)
        XCTAssertEqual(appState.workspaceMutationNamespaceDepth, 0)
    }

    func testUnopenedSourceRenameRejectsEveryManagedDestinationOwner() throws {
        for ownerKind in WorkspaceDestinationOwnerKind.allCases {
            let fixture = try makeFixture(
                files: [
                    "current.md": "Current",
                    "source.md": "Source",
                    "owned.md": "Owned",
                ],
                currentPath: "current.md"
            )
            defer { cleanUp(fixture) }
            let appState = fixture.appState
            let ownedLocation = try fixture.location("owned.md")

            switch ownerKind {
            case .cached:
                _ = try fixture.installSession(path: "owned.md", storage: .cached)
            case .retired:
                _ = try fixture.installSession(path: "owned.md", storage: .retired)
            case .detached:
                _ = try fixture.installSession(path: "owned.md", storage: .cached)
                appState.detachedSessionURLs.insert(ownedLocation.fileURL)
            case .recovery:
                let recoverySession = DocumentSession(
                    text: "Owned",
                    url: ownedLocation.fileURL,
                    fileKind: .markdown
                )
                appState.workspaceMutationTextRecoverySessions[UUID()] = recoverySession
            case .pendingTextRecovery:
                appState.pendingWorkspaceMutationTextRecoveryRecords = [
                    WorkspaceMutationTextRecoveryRecord(
                        originalURL: fixture.url("earlier-recovery.md"),
                        fileKind: .markdown,
                        source: "Earlier recovery",
                        revision: 1,
                        reason: .indeterminateMutation
                    ),
                    WorkspaceMutationTextRecoveryRecord(
                        originalURL: ownedLocation.fileURL,
                        fileKind: .markdown,
                        source: "Owned recovery",
                        revision: 1,
                        reason: .indeterminateMutation
                    ),
                ]
                appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
                XCTAssertEqual(appState.pendingWorkspaceMutationTextRecoveryRecords.count, 1)
            case .pendingOperationRecovery:
                appState.pendingWorkspaceMutationOperationRecoveryRecords = try [
                    makeCreationOperationRecoveryRecord(
                        rootURL: fixture.rootURL,
                        destinationRelativePath: "owned.md"
                    ),
                ]
            }
            try FileManager.default.removeItem(at: ownedLocation.fileURL)
            let source = try fixture.location("source.md")

            XCTAssertThrowsError(
                try appState.renameWorkspaceItem(
                    at: source,
                    to: "owned.md",
                    expecting: fixture.expectation("source.md"),
                    sourceParentExpectation: fixture.parentExpectation("source.md")
                ),
                "unopened source must not replace a \(ownerKind) destination owner"
            )
            XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "Source")
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedLocation.fileURL.path))
        }
    }

    func testWorkspaceCreateRejectsEveryManagedDestinationOwner() throws {
        for ownerKind in WorkspaceDestinationOwnerKind.allCases {
            let fixture = try makeFixture(
                files: [
                    "current.md": "Current",
                    "owned.md": "Owned",
                ],
                currentPath: "current.md"
            )
            defer { cleanUp(fixture) }
            let appState = fixture.appState
            let ownedLocation = try fixture.location("owned.md")

            switch ownerKind {
            case .cached:
                _ = try fixture.installSession(path: "owned.md", storage: .cached)
            case .retired:
                _ = try fixture.installSession(path: "owned.md", storage: .retired)
            case .detached:
                _ = try fixture.installSession(path: "owned.md", storage: .cached)
                appState.detachedSessionURLs.insert(ownedLocation.fileURL)
            case .recovery:
                let recoverySession = DocumentSession(
                    text: "Owned",
                    url: ownedLocation.fileURL,
                    fileKind: .markdown
                )
                appState.workspaceMutationTextRecoverySessions[UUID()] = recoverySession
            case .pendingTextRecovery:
                appState.pendingWorkspaceMutationTextRecoveryRecords = [
                    WorkspaceMutationTextRecoveryRecord(
                        originalURL: fixture.url("earlier-recovery.md"),
                        fileKind: .markdown,
                        source: "Earlier recovery",
                        revision: 1,
                        reason: .indeterminateMutation
                    ),
                    WorkspaceMutationTextRecoveryRecord(
                        originalURL: ownedLocation.fileURL,
                        fileKind: .markdown,
                        source: "Owned recovery",
                        revision: 1,
                        reason: .indeterminateMutation
                    ),
                ]
                appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
                XCTAssertEqual(appState.pendingWorkspaceMutationTextRecoveryRecords.count, 1)
            case .pendingOperationRecovery:
                appState.pendingWorkspaceMutationOperationRecoveryRecords = try [
                    makeCreationOperationRecoveryRecord(
                        rootURL: fixture.rootURL,
                        destinationRelativePath: "owned.md"
                    ),
                ]
            }
            try FileManager.default.removeItem(at: ownedLocation.fileURL)

            appState.createWorkspaceFile(named: "owned.md", inDirectoryID: nil)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ownedLocation.fileURL.path),
                "create must not replace a \(ownerKind) destination owner"
            )
            XCTAssertNotNil(appState.presentedError)
        }
    }

    func testUnopenedSourceRenameRejectsRecoveryOwnedDestinationDescendant() throws {
        for ownerKind in WorkspaceDestinationOwnerKind.allCases {
            let fixture = try makeFixture(
                files: [
                    "current.md": "Current",
                    "source.md": "Source",
                    "archive/post.md": "Owned",
                ],
                currentPath: "current.md"
            )
            defer { cleanUp(fixture) }
            try installWorkspaceDestinationOwner(
                ownerKind,
                relativePath: "archive/post.md",
                fixture: fixture
            )
            try FileManager.default.removeItem(at: fixture.url("archive"))
            let source = try fixture.location("source.md")

            XCTAssertThrowsError(
                try fixture.appState.renameWorkspaceItem(
                    at: source,
                    to: "archive",
                    expecting: fixture.expectation("source.md"),
                    sourceParentExpectation: fixture.parentExpectation("source.md")
                ),
                "regular-file rename must preserve a \(ownerKind) descendant owner"
            )
            XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "Source")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("archive").path))
        }
    }

    func testWorkspaceFileCreateRejectsRecoveryOwnedDestinationDescendant() throws {
        for ownerKind in WorkspaceDestinationOwnerKind.allCases {
            let fixture = try makeFixture(
                files: [
                    "current.md": "Current",
                    "archive/post.md": "Owned",
                ],
                currentPath: "current.md"
            )
            defer { cleanUp(fixture) }
            try installWorkspaceDestinationOwner(
                ownerKind,
                relativePath: "archive/post.md",
                fixture: fixture
            )
            try FileManager.default.removeItem(at: fixture.url("archive"))

            fixture.appState.createWorkspaceFile(named: "archive", inDirectoryID: nil)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.url("archive").path),
                "regular-file create must preserve a \(ownerKind) descendant owner"
            )
            XCTAssertNotNil(fixture.appState.presentedError)
        }
    }

    func testDestinationOwnershipRejectsPathInsideRecoveryOwnedAncestor() throws {
        for ownerKind in WorkspaceDestinationOwnerKind.allCases {
            let fixture = try makeFixture(
                files: [
                    "current.md": "Current",
                    "archive.md": "Owned",
                ],
                currentPath: "current.md"
            )
            defer { cleanUp(fixture) }
            try installWorkspaceDestinationOwner(
                ownerKind,
                relativePath: "archive.md",
                fixture: fixture
            )
            try FileManager.default.removeItem(at: fixture.url("archive.md"))
            try FileManager.default.createDirectory(
                at: fixture.url("archive.md"),
                withIntermediateDirectories: false
            )

            XCTAssertThrowsError(
                try fixture.appState.validateWorkspaceMutationDestinationOwnership(
                    fixture.location("archive.md/post.md")
                ),
                "a destination below a \(ownerKind) owner must remain reserved"
            )
        }
    }

    func testWorkspaceFileCreateDoesNotTreatPrefixSiblingAsOwnedDescendant() throws {
        let fixture = try makeFixture(
            files: [
                "current.md": "Current",
                "archive-copy/post.md": "Owned",
            ],
            currentPath: "current.md"
        )
        defer { cleanUp(fixture) }
        fixture.appState.pendingWorkspaceMutationOperationRecoveryRecords = try [
            makeCreationOperationRecoveryRecord(
                rootURL: fixture.rootURL,
                destinationRelativePath: "archive-copy/post.md"
            ),
        ]

        fixture.appState.createWorkspaceFile(named: "archive", inDirectoryID: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("archive").path))
    }

    func testRenamePublishesEquivalentLiteralSpellingAndRetargetsSessionState() throws {
        let spellingPairs = [
            ("post.md", "Post.md"),
            ("cafe\u{0301}.md", "caf\u{00E9}.md"),
        ]

        for (sourceName, destinationName) in spellingPairs {
            let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
            let fixture = try makeFixture(
                files: [sourceName: "Original"],
                currentPath: sourceName,
                reportedTrashBookmarkAccess: bookmarkAccess
            )
            defer { cleanUp(fixture) }
            let source = try fixture.location(sourceName)
            let destination = try fixture.location(destinationName)
            guard try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(of: source) else {
                throw XCTSkip("Equivalent-spelling rename requires a case-insensitive test volume")
            }
            let session = fixture.appState.currentDocument
            fixture.operationRecoveryStore.onUpsert = { record in
                guard case let .relocation(relocation) = record.payload,
                      relocation.sessionCommitPhase == .committedCleanup
                else {
                    return
                }
                bookmarkAccess.redirectExistingBookmarks(
                    createdFor: source.fileURL,
                    to: destination.fileURL
                )
            }

            try fixture.appState.renameWorkspaceItem(
                at: source,
                to: destinationName,
                expecting: fixture.expectation(sourceName),
                sourceParentExpectation: fixture.parentExpectation(sourceName)
            )

            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
                .map { Array($0.utf8) }
            XCTAssertFalse(names.contains(Array(sourceName.utf8)))
            XCTAssertTrue(names.contains(Array(destinationName.utf8)))
            let stateURL = try XCTUnwrap(fixture.appState.sessionStateURL(for: session))
            XCTAssertTrue(fixture.appState.exactFileURLSpellingMatches(
                stateURL,
                destination.fileURL
            ))
            XCTAssertTrue(fixture.appState.sessionCache[destination.fileURL] === session)
            XCTAssertEqual(
                fixture.appState.anchoredSessionFileBinding(for: session)?.location,
                destination
            )
            XCTAssertEqual(fixture.appState.sessionPolicy.dirtyState(for: destination.fileURL), false)
            XCTAssertTrue(fixture.operationRecoveryStore.records.isEmpty)
            XCTAssertTrue(fixture.appState.workspaceMutationRecoveries.isEmpty)
            XCTAssertTrue(
                fixture.appState.indeterminateWorkspaceMutationSessions.isEmpty
            )
        }
    }

    func testEquivalentSpellingRenameDoesNotHideDetachedDestinationOwner() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let destination = try fixture.location("Post.md")
        guard try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(of: source) else {
            throw XCTSkip("Equivalent-spelling rename requires a case-insensitive test volume")
        }
        fixture.appState.detachedSessionURLs.insert(destination.fileURL)

        XCTAssertThrowsError(
            try fixture.appState.renameWorkspaceItem(
                at: source,
                to: "Post.md",
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
            .map { Array($0.utf8) }
        XCTAssertTrue(names.contains(Array("post.md".utf8)))
        XCTAssertFalse(names.contains(Array("Post.md".utf8)))
    }

    func testRenamePreservesLiteralLeadingAndTrailingWhitespaceThroughAppState() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let literalName = "  renamed.md  "
        let destination = try fixture.location(literalName)
        let session = fixture.appState.currentDocument

        try fixture.appState.renameWorkspaceItem(
            at: source,
            to: literalName,
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
            .map { Array($0.utf8) }
        XCTAssertTrue(names.contains(Array(literalName.utf8)))
        XCTAssertFalse(names.contains(Array("renamed.md".utf8)))
        let stateURL = try XCTUnwrap(fixture.appState.sessionStateURL(for: session))
        XCTAssertTrue(fixture.appState.exactFileURLSpellingMatches(
            stateURL,
            destination.fileURL
        ))
    }

    func testRenameRejectsAllWhitespaceBeforePersistingRecoveryIntent() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let allWhitespaceName = " \t\n "

        XCTAssertThrowsError(
            try fixture.appState.renameWorkspaceItem(
                at: source,
                to: allWhitespaceName,
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        ) { error in
            guard case WorkspaceMutationError.invalidName = error else {
                return XCTFail("Expected invalidName, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "Original")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url(allWhitespaceName).path
        ))
        XCTAssertEqual(bookmarkAccess.makeCallCount, 0)
        XCTAssertTrue(fixture.operationRecoveryStore.records.isEmpty)
    }

    func testExactBytePathMatchingExcludesCanonicalAndPrefixSiblings() {
        let nfc = "Caf\u{00E9}"
        let nfd = "Cafe\u{0301}"

        XCTAssertFalse(workspaceMutationRelativePathIsAffected(
            "\(nfd)/post.md",
            source: nfc,
            sourceIsDirectory: true
        ))
        XCTAssertFalse(workspaceMutationRelativePathIsAffected(
            "drafts-copy/post.md",
            source: "drafts",
            sourceIsDirectory: true
        ))
        XCTAssertTrue(workspaceMutationRelativePathIsAffected(
            "\(nfd)/nested/post.md",
            source: nfd,
            sourceIsDirectory: true
        ))
        XCTAssertFalse(workspaceMutationRelativePathIsAffected(
            "\(nfd)/post.md.bak",
            source: "\(nfd)/post.md",
            sourceIsDirectory: false
        ))
    }

    func testRenameRekeysPromptObservationFileKindAndImageAuthority() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let oldLocation = try fixture.location("post.md")
        let newLocation = try fixture.location("post.mdx")
        let binding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        try "External".write(
            to: oldLocation.fileURL,
            atomically: false,
            encoding: .utf8
        )
        let oldPreparedAuthority = try prepareEditorImageAssetDocumentAuthority(
            at: oldLocation,
            expecting: binding.identity
        )
        let observation = ObservedRetainedFileVersion(
            location: oldLocation,
            file: MarkdownFile(
                url: oldLocation.fileURL,
                text: "External",
                fileKind: .markdown
            ),
            identity: binding.identity,
            sha256Digest: AppState.contentHash("External"),
            preparedImageAssetAuthority: oldPreparedAuthority
        )
        appState.pendingExternalTexts[oldLocation.fileURL] = observation.file.text
        appState.pendingExternalFileVersions[oldLocation.fileURL] = observation
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: oldLocation.fileURL)

        try appState.renameWorkspaceItem(
            at: oldLocation,
            to: "post.mdx",
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        XCTAssertNil(appState.pendingExternalTexts[oldLocation.fileURL])
        XCTAssertNil(appState.pendingExternalFileVersions[oldLocation.fileURL])
        XCTAssertEqual(appState.pendingExternalTexts[newLocation.fileURL], "External")
        let relocatedObservation = try XCTUnwrap(
            appState.pendingExternalFileVersions[newLocation.fileURL]
        )
        XCTAssertEqual(relocatedObservation.location, newLocation)
        XCTAssertEqual(relocatedObservation.file.url, newLocation.fileURL)
        XCTAssertEqual(relocatedObservation.file.fileKind, .mdx)
        XCTAssertEqual(session.fileKind, .mdx)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, newLocation.fileURL)
        XCTAssertTrue(
            relocatedObservation.preparedImageAssetAuthority?.matches(
                location: newLocation,
                identity: binding.identity
            ) == true
        )
        XCTAssertTrue(
            appState.editorImageAssetDocumentAuthorities[ObjectIdentifier(session)]?.matches(
                location: newLocation,
                identity: binding.identity
            ) == true
        )
    }

    func testCapturedImageInserterCannotOutliveWorkspaceMutationQuarantine() async throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let sessionIdentity = ObjectIdentifier(session)
        appState.indeterminateWorkspaceMutationSessions.insert(sessionIdentity)
        appState.discardEditorImageAssetDocumentAuthority(for: session)

        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])

        XCTAssertTrue(insertion.relativePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("assets/image.png").path
        ))
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
    }

    func testIndeterminateNamespaceSessionCannotBeEvictedRetiredClosedOrRebound() throws {
        let fixture = try makeFixture(
            files: [
                "current.md": "Current",
                "cached.md": "Cached",
                "retired.md": "Retired",
            ],
            currentPath: "current.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let cached = try fixture.installSession(path: "cached.md", storage: .cached)
        let retired = try fixture.installSession(path: "retired.md", storage: .retired)
        let cachedURL = try fixture.location("cached.md").fileURL
        let retiredURL = try fixture.location("retired.md").fileURL
        let cachedIdentity = ObjectIdentifier(cached)
        let retiredIdentity = ObjectIdentifier(retired)
        appState.indeterminateWorkspaceMutationSessions.formUnion([
            cachedIdentity,
            retiredIdentity,
        ])
        appState.pendingExternalTexts[cachedURL] = "Retained metadata"

        appState.handleSessionEvictions([
            WorkspaceSessionEviction(url: cachedURL, requiresSave: false),
        ])
        appState.finishRetiredEditorDocumentSessionIfPossible(for: retired)
        appState.retainMetadataOnlyForRetiredEditorSessions()

        XCTAssertTrue(appState.sessionCache[cachedURL] === cached)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[retiredURL]?.session === retired)
        XCTAssertEqual(appState.pendingExternalTexts[cachedURL], "Retained metadata")
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: cached))
        XCTAssertTrue(appState.sessionPolicy.dirtyState(for: cachedURL) != nil)
        XCTAssertTrue(try appState.hasStatefulRetainedAuthorityCollision(
            at: cachedURL,
            candidateLocation: fixture.location("cached.md")
        ))
        XCTAssertThrowsError(try appState.closeWorkspaceForReplacement())
        XCTAssertEqual(appState.workspaceRootURL, fixture.rootURL)
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.contains(cachedIdentity))
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.contains(retiredIdentity))
    }

    func testTrashRejectsDirtySessionBeforeCallingRecycler() async throws {
        let recycler = RecordingMutationRecycler()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        fixture.appState.applyDocumentText("Changed", to: fixture.appState.currentDocument)

        await XCTAssertThrowsErrorAsync {
            try await fixture.appState.trashWorkspaceItem(
                at: fixture.location("post.md"),
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("post.md").path))
        let recycledURLs = await recycler.recordedURLs()
        XCTAssertTrue(recycledURLs.isEmpty)
    }

    func testDirectoryTrashRejectsDirtyCachedOwnerBeforeCallingRecycler() async throws {
        let recycler = RecordingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "other.md": "Other",
                "folder/cached.md": "Cached",
            ],
            directories: ["folder"],
            currentPath: "other.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let cached = try fixture.installSession(
            path: "folder/cached.md",
            storage: .cached
        )
        fixture.appState.applyDocumentText("Dirty cached owner", to: cached)

        await XCTAssertThrowsErrorAsync {
            try await fixture.appState.trashWorkspaceItem(
                at: fixture.location("folder"),
                expecting: fixture.expectation("folder"),
                sourceParentExpectation: fixture.parentExpectation("folder")
            )
        }

        let recycledURLs = await recycler.recordedURLs()
        XCTAssertTrue(recycledURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("folder").path))
    }

    func testDirectoryTrashRejectsPendingEditorSourceOwnerBeforeCallingRecycler() async throws {
        let recycler = RecordingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "other.md": "Other",
                "folder/bound.md": "Bound",
            ],
            directories: ["folder"],
            currentPath: "other.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let bound = try fixture.installSession(
            path: "folder/bound.md",
            storage: .cached
        )
        let binding = fixture.appState.editorDocumentBinding(for: bound)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        fixture.appState.pendingEditorSourceInstallations[installation] = bound

        await XCTAssertThrowsErrorAsync {
            try await fixture.appState.trashWorkspaceItem(
                at: fixture.location("folder"),
                expecting: fixture.expectation("folder"),
                sourceParentExpectation: fixture.parentExpectation("folder")
            )
        }

        let recycledURLs = await recycler.recordedURLs()
        XCTAssertTrue(recycledURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("folder").path))
    }

    func testTrashCleanCurrentSessionClearsAllAuthorityWithoutRecreatingFile() async throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recycler: RemovingMutationRecycler()
        )
        defer { cleanUp(fixture) }
        let session = fixture.appState.currentDocument
        let location = try fixture.location("post.md")

        try await fixture.appState.trashWorkspaceItem(
            at: location,
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
        XCTAssertNil(fixture.appState.currentDocument.fileURL)
        XCTAssertNil(fixture.appState.sessionCache[location.fileURL])
        XCTAssertNil(fixture.appState.anchoredSessionFileBinding(for: session))
        XCTAssertNil(
            fixture.appState.editorImageAssetDocumentAuthorities[ObjectIdentifier(session)]
        )
        XCTAssertNil(fixture.appState.autosaveTask)
    }

    func testTrashSymbolicLinkUsesLexicalEntryAndDoesNotDetachTargetSession() async throws {
        let fixture = try makeFixture(
            files: ["target.md": "Target"],
            currentPath: "target.md",
            recycler: RemovingMutationRecycler()
        )
        defer { cleanUp(fixture) }
        let target = fixture.url("target.md")
        let link = fixture.url("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let session = fixture.appState.currentDocument
        let targetLocation = try fixture.location("target.md")

        try await fixture.appState.trashWorkspaceItem(
            at: fixture.location("alias.md"),
            expecting: fixture.expectation("alias.md"),
            sourceParentExpectation: fixture.parentExpectation("alias.md")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Target")
        XCTAssertTrue(fixture.appState.currentDocument === session)
        XCTAssertEqual(fixture.appState.sessionStateURL(for: session), targetLocation.fileURL)
        XCTAssertFalse(fixture.appState.detachedSessionURLs.contains(targetLocation.fileURL))
        XCTAssertNil(fixture.appState.missingFilePrompt)
    }

    func testWorkspaceCreationWithUnavailableDirectoryNeverFallsBackToRoot() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }

        fixture.appState.createWorkspaceFile(
            named: "misplaced.md",
            inDirectoryID: "directory:missing"
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("misplaced.md").path
        ))
        XCTAssertNotNil(fixture.appState.presentedError)
    }

    func testWorkspaceCreationRejectsDirectoryReplacedAfterSnapshot() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            directories: ["drafts"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        try FileManager.default.moveItem(
            at: fixture.url("drafts"),
            to: fixture.url("retained-drafts")
        )
        try FileManager.default.createDirectory(
            at: fixture.url("drafts"),
            withIntermediateDirectories: false
        )

        fixture.appState.createWorkspaceFile(
            named: "should-not-exist.md",
            inDirectoryID: "directory:drafts"
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("drafts/should-not-exist.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("retained-drafts/should-not-exist.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("should-not-exist.md").path
        ))
        XCTAssertNotNil(fixture.appState.presentedError)
    }

    func testWorkspaceCreationCannotEscapeThroughReplacementDirectorySymlink() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            directories: ["drafts"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCreationOutside")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(
            at: fixture.url("drafts"),
            to: fixture.url("retained-drafts")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.url("drafts"),
            withDestinationURL: outside
        )

        fixture.appState.createWorkspaceFile(
            named: "escaped.md",
            inDirectoryID: "directory:drafts"
        )
        fixture.appState.createWorkspaceFolder(
            named: "escaped-folder",
            inDirectoryID: "directory:drafts"
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("escaped.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("escaped-folder").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("escaped.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("escaped-folder").path
        ))
        XCTAssertNotNil(fixture.appState.presentedError)
    }

    func testDurableWorkspaceFileCreationOpensReturnedExactIdentity() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        operationStore.onUpsert = { record in
            guard case let .creation(context) = record.payload,
                  context.publicationPhase == .prepared,
                  let stagingPath = context.publicationSourceRelativePath
            else {
                return
            }
            bookmarkAccess.resolutionURLReplacements[fixture.url(stagingPath)] =
                fixture.url("created.md")
        }

        fixture.appState.createWorkspaceFile(
            named: "created.md",
            inDirectoryID: nil
        )

        let createdLocation = try fixture.location("created.md")
        let createdExpectation = try fixture.expectation("created.md")
        let session = fixture.appState.currentDocument
        XCTAssertEqual(session.fileURL, createdLocation.fileURL)
        XCTAssertEqual(
            fixture.appState.anchoredSessionFileBinding(for: session)?.identity,
            createdExpectation.identity
        )
        XCTAssertNil(fixture.appState.presentedError)
    }

    func testDurableUnsupportedWorkspaceFileCreationDoesNotActivateOrFence() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let originalSession = appState.currentDocument
        let destination = fixture.url("notes.txt")
        operationStore.onUpsert = { record in
            guard case let .creation(context) = record.payload,
                  context.publicationPhase == .prepared,
                  let stagingPath = context.publicationSourceRelativePath
            else {
                return
            }
            bookmarkAccess.resolutionURLReplacements[fixture.url(stagingPath)] =
                destination
        }

        appState.createWorkspaceFile(
            named: "notes.txt",
            inDirectoryID: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertNil(appState.sessionCache[destination])
        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(operationStore.records.isEmpty)
        XCTAssertNil(appState.workspaceMutationReconciliationPrompt)
        XCTAssertTrue(appState.workspaceMutationWriteFences.isEmpty)
        XCTAssertNil(appState.presentedError)
        XCTAssertTrue(appState.prepareForTermination())
    }

    func testWorkspaceFileCreationPersistsRootStagingBeforeCallbackAndPublication()
        throws
    {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        struct Observation {
            let record: WorkspaceMutationOperationRecoveryRecord
            let destinationExists: Bool
            let stagingExists: Bool
        }
        let destination = fixture.url("created.md")
        var observations: [Observation] = []
        operationStore.onUpsert = { record in
            guard case let .creation(context) = record.payload else { return }
            if context.publicationPhase == .prepared,
               let stagingPath = context.publicationSourceRelativePath
            {
                bookmarkAccess.resolutionURLReplacements[fixture.url(stagingPath)] =
                    destination
            }
            observations.append(Observation(
                record: record,
                destinationExists: FileManager.default.fileExists(
                    atPath: destination.path
                ),
                stagingExists: context.publicationSourceRelativePath.map {
                    FileManager.default.fileExists(
                        atPath: fixture.url($0).path
                    )
                } ?? false
            ))
        }

        fixture.appState.createWorkspaceFile(
            named: "created.md",
            inDirectoryID: nil
        )

        XCTAssertGreaterThanOrEqual(observations.count, 3)
        XCTAssertEqual(Set(observations.map(\.record.id)).count, 1)
        let plannedObservation = try XCTUnwrap(observations.first {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .planned
        })
        guard case let .creation(planned) = plannedObservation.record.payload else {
            return XCTFail("Expected planned creation payload")
        }
        XCTAssertEqual(planned.publicationPhase, .planned)
        XCTAssertEqual(planned.isPlanned, true)
        XCTAssertFalse(plannedObservation.destinationExists)
        XCTAssertFalse(plannedObservation.stagingExists)
        let stagingPath = try XCTUnwrap(planned.publicationSourceRelativePath)
        XCTAssertTrue(stagingPath.hasPrefix(".plainsong-create-"))
        XCTAssertFalse(stagingPath.contains("/"))
        XCTAssertNil(planned.expectedCreatedItem)
        XCTAssertNil(planned.createdItemBookmarkData)

        let preparedObservation = try XCTUnwrap(observations.first {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .prepared
        })
        guard case let .creation(prepared) = preparedObservation.record.payload else {
            return XCTFail("Expected prepared creation payload")
        }
        XCTAssertEqual(prepared.publicationSourceRelativePath, stagingPath)
        XCTAssertNotNil(prepared.expectedCreatedItem)
        XCTAssertNotNil(prepared.createdItemBookmarkData)
        XCTAssertNotNil(prepared.recoveryExpectation)
        XCTAssertTrue(preparedObservation.stagingExists)
        XCTAssertFalse(preparedObservation.destinationExists)

        let committedObservation = try XCTUnwrap(observations.last {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .committedCleanup
        })
        guard case let .creation(committed) = committedObservation.record.payload else {
            return XCTFail("Expected committed creation payload")
        }
        XCTAssertEqual(committed.publicationSourceRelativePath, stagingPath)
        XCTAssertNotNil(committed.expectedCreatedItem)
        XCTAssertNotNil(committed.createdItemBookmarkData)
        XCTAssertFalse(committedObservation.stagingExists)
        XCTAssertTrue(committedObservation.destinationExists)
        XCTAssertTrue(operationStore.records.isEmpty)
        XCTAssertEqual(fixture.appState.currentDocument.fileURL, destination)
    }

    func testWorkspaceFolderCreationRecordsPreparedArtifactBeforeExclusivePublication()
        throws
    {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let destination = fixture.url("images")
        var observations: [(
            record: WorkspaceMutationOperationRecoveryRecord,
            destinationExists: Bool,
            stagingExists: Bool
        )] = []
        operationStore.onUpsert = { record in
            guard case let .creation(context) = record.payload else { return }
            if context.publicationPhase == .prepared,
               let stagingPath = context.publicationSourceRelativePath
            {
                bookmarkAccess.resolutionURLReplacements[fixture.url(stagingPath)] =
                    destination
            }
            observations.append((
                record,
                FileManager.default.fileExists(
                    atPath: fixture.url(context.destinationRelativePath).path
                ),
                context.publicationSourceRelativePath.map {
                    FileManager.default.fileExists(atPath: fixture.url($0).path)
                } ?? false
            ))
        }

        fixture.appState.createWorkspaceFolder(
            named: "images",
            inDirectoryID: nil
        )

        XCTAssertGreaterThanOrEqual(observations.count, 3)
        XCTAssertEqual(Set(observations.map(\.record.id)).count, 1)
        let plannedObservation = try XCTUnwrap(observations.first {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .planned
        })
        guard case let .creation(planned) = plannedObservation.record.payload else {
            return XCTFail("Expected planned folder creation")
        }
        XCTAssertEqual(planned.publicationPhase, .planned)
        XCTAssertEqual(planned.isPlanned, true)
        XCTAssertFalse(plannedObservation.destinationExists)
        XCTAssertFalse(plannedObservation.stagingExists)
        let stagingPath = try XCTUnwrap(planned.publicationSourceRelativePath)
        XCTAssertTrue(stagingPath.hasPrefix(".plainsong-create-"))
        XCTAssertFalse(stagingPath.contains("/"))

        let preparedObservation = try XCTUnwrap(observations.first {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .prepared
        })
        guard case let .creation(prepared) = preparedObservation.record.payload
        else {
            return XCTFail("Expected prepared folder artifact")
        }
        XCTAssertEqual(prepared.publicationPhase, .prepared)
        XCTAssertEqual(prepared.isPlanned, true)
        XCTAssertNotNil(prepared.expectedCreatedItem)
        XCTAssertNotNil(prepared.createdItemBookmarkData)
        XCTAssertNotNil(prepared.recoveryExpectation)
        XCTAssertEqual(prepared.publicationSourceRelativePath, stagingPath)
        XCTAssertTrue(preparedObservation.stagingExists)
        XCTAssertFalse(preparedObservation.destinationExists)

        let committedObservation = try XCTUnwrap(observations.last {
            guard case let .creation(context) = $0.record.payload else { return false }
            return context.publicationPhase == .committedCleanup
        })
        XCTAssertTrue(committedObservation.destinationExists)
        XCTAssertFalse(committedObservation.stagingExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("images").path))
        XCTAssertTrue(operationStore.records.isEmpty)
    }

    func testCreationCallbackJournalFailureRetainsRootStagingBeforePublication()
        throws
    {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let originalSession = fixture.appState.currentDocument
        var plannedID: UUID?
        operationStore.onUpsert = { record in
            guard plannedID == nil,
                  case let .creation(context) = record.payload,
                  context.publicationPhase == .planned
            else {
                return
            }
            plannedID = record.id
            operationStore.upsertError = TestWorkspaceMutationRecoveryStoreError.failed
        }

        fixture.appState.createWorkspaceFolder(named: "images", inDirectoryID: nil)

        let recoveryID = try XCTUnwrap(plannedID)
        guard case let .creation(durablePlanned)? =
            operationStore.records[recoveryID]?.payload
        else {
            return XCTFail("Expected the durable planned record to survive")
        }
        XCTAssertEqual(durablePlanned.publicationPhase, .planned)
        XCTAssertNil(durablePlanned.expectedCreatedItem)
        XCTAssertNil(durablePlanned.createdItemBookmarkData)
        let stagingPath = try XCTUnwrap(durablePlanned.publicationSourceRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("images").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.url(stagingPath).path
        ))
        guard case let .creation(inMemoryRecovery)? =
            fixture.appState.workspaceMutationRecoveries[recoveryID]
        else {
            return XCTFail("Expected prepared in-memory creation recovery")
        }
        XCTAssertEqual(inMemoryRecovery.publicationState, .prepared)
        XCTAssertEqual(inMemoryRecovery.publicationSource?.relativePath, stagingPath)
        XCTAssertNotNil(inMemoryRecovery.expectedCreatedItem)
        XCTAssertNotNil(inMemoryRecovery.createdItemBookmarkData)
        XCTAssertEqual(
            inMemoryRecovery.recoveryExpectation,
            inMemoryRecovery.expectedCreatedItem
        )
        XCTAssertTrue(fixture.appState.currentDocument === originalSession)
        XCTAssertNotNil(fixture.appState.presentedError)
    }

    func testWorkspaceCreationIsFencedDuringTrashAndNeverFallsBackToRoot() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["drafts/post.md": "Original"],
            directories: ["drafts"],
            currentPath: "drafts/post.md",
            recycler: recycler,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let location = try fixture.location("drafts/post.md")
        let expectation = try fixture.expectation("drafts/post.md")

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: location,
                expecting: expectation,
                sourceParentExpectation: fixture.parentExpectation("drafts/post.md")
            )
        }
        await recycler.waitUntilCalled()

        appState.createWorkspaceFolder(
            named: "should-not-exist",
            inDirectoryID: "directory:drafts"
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("should-not-exist").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("drafts/should-not-exist").path
        ))
        XCTAssertNotNil(appState.presentedError)

        let movedURLs = try await recycler.moveRequestsWithoutCompleting()
        let reportedTrashURL = try XCTUnwrap(movedURLs.first)
        bookmarkAccess.redirectExistingBookmarks(
            createdFor: location.fileURL,
            to: reportedTrashURL
        )
        await recycler.completeMovedRequests()
        try await trashTask.value
    }

    func testEditingWhileTrashIsInFlightKeepsDetachedRecoveryAndNeverRecreatesPath() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "post.md": "Original",
                "outside.md": "Outside",
                "editor-only.md": "Editor only",
            ],
            currentPath: "post.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.preferences.setAutosaveIntervalSeconds(
            PlainsongPreferences.minimumAutosaveIntervalSeconds
        )
        let session = appState.currentDocument
        let outside = try fixture.installSession(path: "outside.md", storage: .cached)
        let editorOnly = try fixture.installSession(path: "editor-only.md", storage: .cached)
        let editorBinding = appState.editorDocumentBinding(for: editorOnly)
        let editorInstallation = EditorDocumentBindingInstallation(
            bindingID: editorBinding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        editorBinding.onLifecycle(.installed(editorInstallation))
        try appState.sessionCache[fixture.location("editor-only.md").fileURL] = nil
        let outsideEventGeneration = appState.currentExternalDiskEventGeneration(for: outside)
        let editorOnlyEventGeneration = appState.currentExternalDiskEventGeneration(
            for: editorOnly
        )
        let location = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: location,
                expecting: expectation,
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        }
        await recycler.waitUntilCalled()
        let mutationGeneration = appState.workspaceGeneration
        appState.refreshWorkspaceAfterFileSystemChange()
        XCTAssertEqual(appState.workspaceGeneration, mutationGeneration)
        XCTAssertTrue(appState.workspaceMutationRefreshPending)
        XCTAssertNil(appState.workspaceReloadTask)
        XCTAssertGreaterThan(
            appState.currentExternalDiskEventGeneration(for: outside),
            outsideEventGeneration
        )
        XCTAssertGreaterThan(
            appState.currentExternalDiskEventGeneration(for: editorOnly),
            editorOnlyEventGeneration
        )
        XCTAssertTrue(
            appState.workspaceMutationWriteFences.contains(ObjectIdentifier(outside))
        )
        XCTAssertTrue(
            appState.workspaceMutationWriteFences.contains(ObjectIdentifier(editorOnly))
        )
        XCTAssertThrowsError(try appState.closeWorkspaceForReplacement())
        XCTAssertEqual(appState.workspaceRootURL, fixture.rootURL)
        appState.applyDocumentText("Typed during trash", to: session)
        await recycler.complete()
        try await trashTask.value

        XCTAssertEqual(appState.workspaceMutationNamespaceDepth, 0)
        XCTAssertFalse(appState.workspaceMutationRefreshPending)
        XCTAssertTrue(appState.workspaceMutationWriteFences.isEmpty)
        XCTAssertGreaterThan(appState.workspaceGeneration, mutationGeneration)
        XCTAssertGreaterThan(
            appState.currentExternalDiskEventGeneration(for: outside),
            outsideEventGeneration
        )
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(session.text, "Typed during trash")
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, location.fileURL)
        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))
        XCTAssertTrue(appState.editorBindingInstallations[editorInstallation] === editorOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))
    }

    func testTerminationDuringTrashPersistsLatestEditorSourceAndCancelsQuit() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recycler: recycler,
            recoveryStore: store
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let location = try fixture.location("post.md")
        let latest = "NFD e\u{0301} 👩🏽‍💻\nTyped during Trash"

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: location,
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        }
        await recycler.waitUntilCalled()
        let writeAheadRecord = try XCTUnwrap(
            fixture.operationRecoveryStore.records.values.first
        )
        guard case let .trash(writeAheadTrash) = writeAheadRecord.payload else {
            return XCTFail("Trash must publish its operation journal before awaiting recycler")
        }
        XCTAssertEqual(writeAheadTrash.sourceRelativePath, "post.md")
        XCTAssertNotNil(writeAheadTrash.recoveryRelativePath)
        XCTAssertEqual(writeAheadRecord.textRecoveryRecords.first?.source, "Original")
        appState.applyDocumentText(latest, to: session)

        XCTAssertFalse(appState.prepareForTermination())
        let record = try XCTUnwrap(store.records.values.first)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(record.source.utf8.elementsEqual(latest.utf8))
        XCTAssertEqual(record.revision, session.version)
        XCTAssertEqual(record.originalURL, location.fileURL)
        XCTAssertEqual(record.reason, .trash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.fileURL.path))

        await recycler.complete()
        try await trashTask.value

        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))
        let didPrepareForTermination = appState.prepareForTermination()
        let sessionIdentity = ObjectIdentifier(session)
        let textRecoveryContext =
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]
        let logicalRevision = textRecoveryContext.map {
            appState.workspaceMutationTextRecoveryLogicalRevision(
                for: session,
                context: $0
            )
        }
        let presentedTitle = appState.presentedError?.title ?? "nil"
        let presentedMessage = appState.presentedError?.message ?? "nil"
        XCTAssertTrue(
            didPrepareForTermination,
            "title=\(presentedTitle) " +
                "message=\(presentedMessage) " +
                "namespaceDepth=\(appState.workspaceMutationNamespaceDepth) " +
                "operationRecoveries=\(appState.workspaceMutationRecoveries.count) " +
                "operationRecords=\(fixture.operationRecoveryStore.records.count) " +
                "dirty=\(session.isDirty) " +
                "pendingEditorSource=\(appState.hasPendingEditorSource(for: session)) " +
                "persistedRevision=\(String(describing: textRecoveryContext?.persistedRevision)) " +
                "logicalRevision=\(String(describing: logicalRevision))"
        )
    }

    func testTerminationCancelsWhenTrashRecoveryCannotBePersisted() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recycler: recycler,
            recoveryStore: store
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: fixture.location("post.md"),
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        }
        await recycler.waitUntilCalled()
        store.upsertError = ControlledMutationRecyclerError.failed
        appState.applyDocumentText("Must survive", to: appState.currentDocument)

        XCTAssertFalse(appState.prepareForTermination())
        XCTAssertEqual(appState.presentedError?.title, "Could Not Preserve Recovery Copy")
        XCTAssertEqual(store.records.values.first?.source, "Original")
        XCTAssertEqual(
            fixture.operationRecoveryStore.records.values.first?
                .textRecoveryRecords.first?.source,
            "Must survive"
        )

        await recycler.complete()
        await XCTAssertThrowsErrorAsync {
            try await trashTask.value
        }
    }

    func testTrashInitialRecoveryFailureRejectsBeforeRecyclerAndUnwindsFence() async throws {
        let recycler = RecordingMutationRecycler()
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        store.upsertError = ControlledMutationRecyclerError.failed
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recycler: recycler,
            recoveryStore: store
        )
        defer { cleanUp(fixture) }

        await XCTAssertThrowsErrorAsync {
            try await fixture.appState.trashWorkspaceItem(
                at: fixture.location("post.md"),
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        }

        let recycledURLs = await recycler.recordedURLs()
        XCTAssertTrue(recycledURLs.isEmpty)
        XCTAssertEqual(fixture.appState.workspaceMutationNamespaceDepth, 0)
        XCTAssertTrue(fixture.appState.workspaceMutationWriteFences.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.url("post.md").path)
        )
    }

    func testCancelledTerminationDoesNotLeaveCleanRecoverySessionStronglyRetained() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Original",
                "unopened.md": "Unopened",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let current = appState.currentDocument
        let currentRecords = try appState.prepareWorkspaceTrashRecords(
            source: fixture.location("post.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceMutationTextRecovery(
            for: currentRecords,
            reason: .trash
        )

        let source = try fixture.location("unopened.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: fixture.location("renamed-unopened.md"),
            expectation: fixture.expectation("unopened.md")
        )
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )

        XCTAssertFalse(appState.prepareForTermination())
        XCTAssertNil(
            appState.workspaceMutationTextRecoveryContexts[ObjectIdentifier(current)]
        )
        XCTAssertFalse(
            appState.workspaceMutationTextRecoverySessions.values.contains {
                $0 === current
            }
        )
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
    }

    func testTerminationCancelsWhenAutosaveCannotRemoveObsoleteRecoveryRecord() throws {
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        store.removeError = ControlledMutationRecyclerError.failed
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recoveryStore: store
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let records = try appState.prepareWorkspaceTrashRecords(
            source: fixture.location("post.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        appState.applyDocumentText("Safely autosaved before quit", to: session)

        XCTAssertFalse(appState.prepareForTermination())
        XCTAssertFalse(session.isDirty)
        XCTAssertNotNil(
            appState.workspaceMutationTextRecoveryContexts[ObjectIdentifier(session)]
        )
        XCTAssertEqual(store.records.values.first?.source, "Safely autosaved before quit")
    }

    func testFailedRecoveryRemovalPersistsLatestPendingRevisionBeforeReturning() throws {
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            recoveryStore: store
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let records = try appState.prepareWorkspaceTrashRecords(
            source: fixture.location("post.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        try appState.persistWorkspaceMutationTextRecovery(for: session)
        appState.applyDocumentText("Latest pending recovery text", to: session)
        let sessionIdentity = ObjectIdentifier(session)
        let recoveryID = try XCTUnwrap(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]?.recoveryID
        )
        XCTAssertNotNil(appState.workspaceMutationTextRecoveryTasks[sessionIdentity])
        XCTAssertEqual(store.records[recoveryID]?.source, "Original")
        store.removeError = ControlledMutationRecyclerError.failed

        XCTAssertFalse(appState.clearWorkspaceMutationTextRecovery(for: session))

        XCTAssertEqual(store.records[recoveryID]?.source, "Latest pending recovery text")
        XCTAssertEqual(store.records[recoveryID]?.revision, session.version)
        XCTAssertEqual(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]?.persistedRevision,
            session.version
        )
        XCTAssertNil(appState.workspaceMutationTextRecoveryTasks[sessionIdentity])
    }

    func testRecoveryRemovalThatDeletesBeforeThrowRepairsSameRevisionAndRestarts() throws {
        let store = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["post.md": "Exact recovery"],
            currentPath: "post.md",
            recoveryStore: store
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let records = try appState.prepareWorkspaceTrashRecords(
            source: fixture.location("post.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        try appState.persistWorkspaceMutationTextRecovery(for: session)
        let sessionIdentity = ObjectIdentifier(session)
        let recoveryID = try XCTUnwrap(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]?.recoveryID
        )
        let persisted = try XCTUnwrap(store.records[recoveryID])
        store.removeRecordBeforeThrow = true
        store.removeError = TestWorkspaceMutationRecoveryStoreError.failed

        XCTAssertFalse(appState.clearWorkspaceMutationTextRecovery(for: session))

        let repaired = try XCTUnwrap(store.records[recoveryID])
        XCTAssertEqual(repaired.id, persisted.id)
        XCTAssertEqual(repaired.originalURL, persisted.originalURL)
        XCTAssertEqual(repaired.fileKind, persisted.fileKind)
        XCTAssertEqual(repaired.source, persisted.source)
        XCTAssertEqual(repaired.revision, persisted.revision)
        XCTAssertEqual(repaired.reason, persisted.reason)
        XCTAssertNotNil(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]
        )
        XCTAssertNil(appState.workspaceMutationTextRecoveryTasks[sessionIdentity])

        let relaunched = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: store,
            shouldRestoreLastOpenedFile: false
        )
        relaunched.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(relaunched.currentDocument.text, persisted.source)
        XCTAssertTrue(relaunched.currentDocument.isDirty)
    }

    func testBackgroundEditDuringDirectoryTrashIsPromotedForDetachedRecovery() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "drafts/current.md": "Current",
                "drafts/background.md": "Background",
            ],
            directories: ["drafts"],
            currentPath: "drafts/current.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let background = try fixture.installSession(
            path: "drafts/background.md",
            storage: .retired
        )
        let backgroundLocation = try fixture.location("drafts/background.md")
        let expectation = try fixture.expectation("drafts")

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: fixture.location("drafts"),
                expecting: expectation,
                sourceParentExpectation: fixture.parentExpectation("drafts")
            )
        }
        await recycler.waitUntilCalled()
        appState.applyDocumentText("Background changed", to: background)
        await recycler.complete()
        try await trashTask.value

        XCTAssertTrue(appState.currentDocument === background)
        XCTAssertEqual(background.text, "Background changed")
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, backgroundLocation.fileURL)
        XCTAssertTrue(appState.detachedSessionURLs.contains(backgroundLocation.fileURL))
        XCTAssertTrue(
            appState.retiredEditorDocumentSessions[backgroundLocation.fileURL]?.session === background
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("drafts").path))
    }

    func testMultipleDetachedTrashEditsRemainNavigableUntilEachCopyIsSaved() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "drafts/current.md": "Current",
                "drafts/background.md": "Background",
            ],
            directories: ["drafts"],
            currentPath: "drafts/current.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let current = appState.currentDocument
        let background = try fixture.installSession(
            path: "drafts/background.md",
            storage: .retired
        )

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: fixture.location("drafts"),
                expecting: fixture.expectation("drafts"),
                sourceParentExpectation: fixture.parentExpectation("drafts")
            )
        }
        await recycler.waitUntilCalled()
        appState.applyDocumentText("Current changed", to: current)
        appState.applyDocumentText("Background changed", to: background)
        await recycler.complete()
        do {
            try await trashTask.value
        } catch {
            return XCTFail("Trash failed before recovery promotion: \(error)")
        }

        XCTAssertTrue(appState.currentDocument === current)
        let recoveredCurrent = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("recovered-current-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: recoveredCurrent) }
        do {
            try appState.saveDetachedCurrentDocument(
                to: recoveredCurrent
            )
        } catch {
            return XCTFail("Saving the first detached copy failed: \(error)")
        }

        XCTAssertTrue(appState.currentDocument === background)
        XCTAssertEqual(background.text, "Background changed")
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL,
            fixture.url("drafts/background.md")
        )
    }

    func testTrashRecoveryPromotionMovesUnaffectedCurrentAutosaveToBackground() async throws {
        let recycler = ControlledRemovingMutationRecycler()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: [
                "outside.md": "Outside",
                "drafts/background.md": "Background",
            ],
            directories: ["drafts"],
            currentPath: "outside.md",
            recycler: recycler,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.preferences.setAutosaveIntervalSeconds(
            PlainsongPreferences.minimumAutosaveIntervalSeconds
        )
        let outside = appState.currentDocument
        let background = try fixture.installSession(
            path: "drafts/background.md",
            storage: .retired
        )
        appState.applyDocumentText("Outside changed", to: outside)
        XCTAssertNotNil(appState.autosaveTask)

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: fixture.location("drafts"),
                expecting: fixture.expectation("drafts"),
                sourceParentExpectation: fixture.parentExpectation("drafts")
            )
        }
        await recycler.waitUntilCalled()
        appState.applyDocumentText("Background changed", to: background)
        let movedURLs = try await recycler.moveRequestsWithoutCompleting()
        let reportedTrashURL = try XCTUnwrap(movedURLs.first)
        bookmarkAccess.redirectExistingBookmarks(
            createdFor: fixture.url("drafts"),
            to: reportedTrashURL
        )
        await recycler.completeMovedRequests()
        try await trashTask.value

        XCTAssertTrue(appState.currentDocument === background)
        XCTAssertNil(appState.autosaveTask)
        XCTAssertNotNil(
            appState.sessionAutosaveTasks[ObjectIdentifier(outside)]
        )

        try await Task.sleep(nanoseconds: 650_000_000)

        XCTAssertEqual(
            try String(contentsOf: fixture.url("outside.md"), encoding: .utf8),
            "Outside changed"
        )
        XCTAssertFalse(outside.isDirty)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(outside)])
    }

    func testTrashRecyclerFailureKeepsFencedCachedSessionThroughEviction() async throws {
        let recycler = ControlledFailingMutationRecycler()
        let fixture = try makeFixture(
            files: [
                "outside.md": "Outside",
                "target.md": "Target",
            ],
            currentPath: "outside.md",
            recycler: recycler
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let target = try fixture.installSession(path: "target.md", storage: .cached)
        let targetLocation = try fixture.location("target.md")
        let targetIdentity = ObjectIdentifier(target)

        let trashTask = Task { @MainActor in
            try await appState.trashWorkspaceItem(
                at: targetLocation,
                expecting: fixture.expectation("target.md"),
                sourceParentExpectation: fixture.parentExpectation("target.md")
            )
        }
        await recycler.waitUntilCalled()
        XCTAssertTrue(appState.workspaceMutationWriteFences.contains(targetIdentity))

        appState.handleSessionEvictions([
            WorkspaceSessionEviction(url: targetLocation.fileURL, requiresSave: false),
        ])

        XCTAssertTrue(appState.sessionCache[targetLocation.fileURL] === target)
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: target))
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: targetLocation.fileURL), false)

        await recycler.fail()
        await XCTAssertThrowsErrorAsync {
            try await trashTask.value
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetLocation.fileURL.path))
        XCTAssertTrue(appState.sessionCache[targetLocation.fileURL] === target)
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: target))
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: targetLocation.fileURL), false)
        XCTAssertTrue(appState.workspaceMutationWriteFences.isEmpty)
        guard case let .trash(recovery)? =
            appState.workspaceMutationRecoveries.values.first,
            let recoveryLocation = recovery.recoveryLocation
        else {
            return XCTFail("Expected retained staged Trash recovery")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryLocation.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: recoveryLocation.fileURL, encoding: .utf8),
            "Target"
        )
        XCTAssertTrue(
            appState.indeterminateWorkspaceMutationSessions.contains(targetIdentity)
        )
    }

    func testRelocationRecoveryReconcilesSourceWithoutPermanentQuarantine() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let expectation = try fixture.expectation("post.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        XCTAssertEqual(appState.currentDocument.fileURL, source.fileURL)
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: appState.currentDocument))
        XCTAssertNil(appState.workspaceMutationReconciliationPrompt)
    }

    func testRelocationPersistsDestinationParentBookmarkBeforeForwardRename() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        var initialRecord: WorkspaceMutationOperationRecoveryRecord?
        var sourceExistedAtInitialUpsert = false
        var destinationExistedAtInitialUpsert = true
        operationStore.onUpsert = { record in
            guard initialRecord == nil, case .relocation = record.payload else { return }
            initialRecord = record
            sourceExistedAtInitialUpsert = FileManager.default.fileExists(
                atPath: source.fileURL.path
            )
            destinationExistedAtInitialUpsert = FileManager.default.fileExists(
                atPath: destination.fileURL.path
            )
        }

        try fixture.appState.moveWorkspaceItem(
            at: source,
            toDirectoryRelativePath: "archive",
            expecting: fixture.expectation("posts/draft.md"),
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )

        guard case let .relocation(relocation) = try XCTUnwrap(initialRecord).payload else {
            return XCTFail("Expected relocation write-ahead record")
        }
        XCTAssertNotNil(relocation.sourceParentBookmarkData)
        XCTAssertEqual(
            relocation.sourceParentDisplayURL?.path,
            fixture.url("posts").path
        )
        XCTAssertEqual(relocation.sourceLeafName, "draft.md")
        XCTAssertNotNil(relocation.destinationParentBookmarkData)
        XCTAssertEqual(
            relocation.destinationParentDisplayURL?.path,
            fixture.url("archive").path
        )
        XCTAssertEqual(relocation.destinationLeafName, "draft.md")
        XCTAssertNotNil(relocation.relocatedItemBookmarkData)
        XCTAssertEqual(
            relocation.relocatedItemDisplayURL?.path,
            source.fileURL.path
        )
        XCTAssertEqual(relocation.sessionCommitPhase, .pendingSessionCommit)
        XCTAssertTrue(sourceExistedAtInitialUpsert)
        XCTAssertFalse(destinationExistedAtInitialUpsert)
        XCTAssertEqual(bookmarkAccess.makeCallCount, 3)
        XCTAssertEqual(bookmarkAccess.resolveCallCount, 6)
        XCTAssertTrue(operationStore.records.isEmpty)
    }

    func testRelocationBookmarkFailureRejectsBeforeForwardRename() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        bookmarkAccess.makeError = TestWorkspaceMutationRecoveryStoreError.failed
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")

        XCTAssertThrowsError(try fixture.appState.moveWorkspaceItem(
            at: source,
            toDirectoryRelativePath: "archive",
            expecting: fixture.expectation("posts/draft.md"),
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        ))

        XCTAssertEqual(try String(contentsOf: source.fileURL, encoding: .utf8), "Original")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("archive/draft.md").path
        ))
        XCTAssertTrue(fixture.operationRecoveryStore.records.isEmpty)
        XCTAssertTrue(fixture.appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertEqual(fixture.appState.workspaceMutationNamespaceDepth, 0)
    }

    func testProductionBookmarkAccessCapturesDestinationParentInAppSandbox() throws {
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            reportedTrashBookmarkAccess: ProductionReportedTrashBookmarkAccess()
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")

        try fixture.appState.moveWorkspaceItem(
            at: source,
            toDirectoryRelativePath: "archive",
            expecting: fixture.expectation("posts/draft.md"),
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.url("archive/draft.md"), encoding: .utf8),
            "Original"
        )
        XCTAssertTrue(fixture.operationRecoveryStore.records.isEmpty)
    }

    func testProductionItemBookmarkFollowsMovedParentInAppSandbox() throws {
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts"],
            currentPath: "posts/draft.md"
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let bookmarkAccess = ProductionMutationBookmarkAccess()
        let bookmarkData = try bookmarkAccess.makeBookmark(for: source.fileURL)
        let escapedPosts = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("escaped-posts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedPosts) }

        try FileManager.default.moveItem(at: fixture.url("posts"), to: escapedPosts)

        let resolution = try bookmarkAccess.resolveBookmark(bookmarkData)
        let resolvedLocation = try WorkspaceFileSystemLocation(fileURL: resolution.fileURL)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspect(at: resolvedLocation),
            expectation
        )
        XCTAssertEqual(
            resolution.fileURL.path,
            escapedPosts.appendingPathComponent("draft.md").path
        )
    }

    func testProductionParentBookmarkFollowsMovedDirectoryAndRetainsLiteralChild() throws {
        let literalLeafName = " draft.md"
        let fixture = try makeFixture(
            files: ["posts/\(literalLeafName)": "Original"],
            directories: ["posts"],
            currentPath: "posts/\(literalLeafName)"
        )
        defer { cleanUp(fixture) }
        let parentURL = fixture.url("posts")
        let source = try fixture.location("posts/\(literalLeafName)")
        let expectation = try fixture.expectation("posts/\(literalLeafName)")
        let bookmarkAccess = ProductionMutationBookmarkAccess()
        let bookmarkData = try bookmarkAccess.makeBookmark(for: parentURL)
        let escapedPosts = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("escaped-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedPosts) }

        try FileManager.default.moveItem(at: parentURL, to: escapedPosts)

        let resolution = try bookmarkAccess.resolveBookmark(bookmarkData)
        let resolvedParent = try WorkspaceFileSystemRootAuthority(
            rootURL: resolution.fileURL
        )
        let resolvedChild = try resolvedParent.location(relativePath: literalLeafName)
        XCTAssertEqual(resolution.fileURL.path, escapedPosts.path)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: resolvedChild),
            expectation
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: resolution.fileURL.path)
                .map { Array($0.utf8) },
            [Array(literalLeafName.utf8)]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
    }

    func testCommittedCleanupKeepsEscapedDestinationUntilOriginalParentReturns()
        throws
    {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let binding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        let editorBinding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: editorBinding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        editorBinding.onLifecycle(.installed(installation))
        XCTAssertNotNil(appState.editorWriterInstallations[sessionIdentity])
        let observedAuthority = try prepareEditorImageAssetDocumentAuthority(
            at: source,
            expecting: binding.identity
        )
        let observation = ObservedRetainedFileVersion(
            location: source,
            file: MarkdownFile(
                url: source.fileURL,
                text: "Observed",
                fileKind: .markdown
            ),
            identity: binding.identity,
            sha256Digest: AppState.contentHash("Observed"),
            preparedImageAssetAuthority: observedAuthority
        )
        appState.pendingExternalTexts[source.fileURL] = observation.file.text
        appState.pendingExternalFileVersions[source.fileURL] = observation
        appState.externalChangePrompt = .init(fileURL: source.fileURL)

        XCTAssertThrowsError(try appState.moveWorkspaceItem(
            at: source,
            toDirectoryRelativePath: "archive",
            expecting: fixture.expectation("posts/draft.md"),
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        ))

        guard case let .relocation(recovery)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected committed relocation cleanup recovery")
        }
        XCTAssertEqual(recovery.sessionCommitState, .committed)
        XCTAssertFalse(recovery.records.isEmpty)
        XCTAssertEqual(session.fileURL, destination.fileURL)
        XCTAssertTrue(appState.sessionCache[destination.fileURL] === session)
        XCTAssertNil(appState.sessionCache[source.fileURL])
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session)?.location, destination)
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.contains(sessionIdentity))

        let escapedArchive = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("committed-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        try FileManager.default.moveItem(at: fixture.url("archive"), to: escapedArchive)
        try FileManager.default.createDirectory(
            at: fixture.url("archive"),
            withIntermediateDirectories: false
        )
        try "Replacement".write(
            to: fixture.url("archive/occupant.txt"),
            atomically: false,
            encoding: .utf8
        )
        bookmarkAccess.resolutionURLReplacements[fixture.url("archive")] =
            escapedArchive
        operationStore.removeError = nil

        XCTAssertThrowsError(
            try appState.reconcileWorkspaceMutationRecovery(id: recovery.id)
        )
        guard case let .relocation(blocked)? =
            appState.workspaceMutationRecoveries[recovery.id]
        else {
            return XCTFail("Expected committed recovery to remain fail-closed")
        }
        let escapedDestination = try WorkspaceFileSystemLocation(
            fileURL: escapedArchive.appendingPathComponent("draft.md")
        )
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: escapedDestination),
            recovery.expectation
        )
        XCTAssertEqual(
            blocked.destinationParentAuthorityLocation?.fileURL.path,
            escapedDestination.fileURL.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: fixture.url("archive/occupant.txt"), encoding: .utf8),
            "Replacement"
        )
        XCTAssertEqual(session.fileURL, destination.fileURL)
        XCTAssertTrue(appState.sessionCache[destination.fileURL] === session)
        XCTAssertNil(appState.sessionCache[source.fileURL])
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: destination.fileURL), false)
        XCTAssertNil(appState.sessionPolicy.dirtyState(for: source.fileURL))
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session)?.location, destination)
        XCTAssertTrue(appState.editorBindingInstallations[installation] === session)
        XCTAssertTrue(appState.editorDocumentBindingSessions[editorBinding.id] === session)
        XCTAssertNil(appState.editorWriterInstallations[sessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[source.fileURL])
        XCTAssertEqual(appState.pendingExternalTexts[destination.fileURL], "Observed")
        XCTAssertNil(appState.pendingExternalFileVersions[source.fileURL])
        XCTAssertEqual(
            appState.pendingExternalFileVersions[destination.fileURL]?.location,
            destination
        )
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.recoveryID,
            recovery.id
        )
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.operation,
            .relocation
        )
        XCTAssertNil(appState.editorImageAssetDocumentAuthorities[sessionIdentity])
        XCTAssertNotNil(operationStore.records[recovery.id])
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.contains(sessionIdentity))
        XCTAssertEqual(appState.workspaceMutationRecoveryIDBySession[sessionIdentity], recovery.id)

        try FileManager.default.removeItem(at: fixture.url("archive"))
        try FileManager.default.moveItem(at: escapedArchive, to: fixture.url("archive"))
        bookmarkAccess.resolutionURLReplacements[fixture.url("archive")] = nil

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertEqual(
            try String(contentsOf: destination.fileURL, encoding: .utf8),
            "Original"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedArchive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(session.fileURL, destination.fileURL)
        XCTAssertTrue(appState.sessionCache[destination.fileURL] === session)
        XCTAssertNil(appState.sessionCache[source.fileURL])
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: destination.fileURL), false)
        XCTAssertNil(appState.sessionPolicy.dirtyState(for: source.fileURL))
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session)?.location, destination)
        XCTAssertTrue(appState.editorBindingInstallations[installation] === session)
        XCTAssertTrue(appState.editorDocumentBindingSessions[editorBinding.id] === session)
        XCTAssertNil(appState.editorWriterInstallations[sessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[source.fileURL])
        XCTAssertEqual(appState.pendingExternalTexts[destination.fileURL], "Observed")
        XCTAssertNil(appState.pendingExternalFileVersions[source.fileURL])
        XCTAssertEqual(
            appState.pendingExternalFileVersions[destination.fileURL]?.location,
            destination
        )
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, destination.fileURL)
        XCTAssertTrue(
            appState.editorImageAssetDocumentAuthorities[sessionIdentity]?.matches(
                location: destination,
                identity: binding.identity
            ) == true
        )
        XCTAssertNil(appState.workspaceMutationRecoveries[recovery.id])
        XCTAssertNil(operationStore.records[recovery.id])
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.contains(sessionIdentity))
        XCTAssertNil(appState.workspaceMutationRecoveryIDBySession[sessionIdentity])
    }

    func testRelocationRecoveryRestoresEscapedParentWithoutTouchingReplacement() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let sourceParentExpectation = try fixture.parentExpectation("posts/draft.md")
        let destinationParentExpectation = try fixture.parentExpectation("archive/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation
        )
        let escapedArchive = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("escaped-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        try FileManager.default.moveItem(at: fixture.url("archive"), to: escapedArchive)
        try FileManager.default.createDirectory(
            at: fixture.url("archive"),
            withIntermediateDirectories: false
        )
        try "Replacement".write(
            to: fixture.url("archive/occupant.txt"),
            atomically: false,
            encoding: .utf8
        )
        bookmarkAccess.resolutionURLReplacements[fixture.url("archive")] =
            escapedArchive
        let escapedItemURL = escapedArchive.appendingPathComponent("draft.md")
        bookmarkAccess.resolutionURLReplacements[source.fileURL] = escapedItemURL
        bookmarkAccess.onResolve = { _, _ in
            guard !FileManager.default.fileExists(atPath: escapedItemURL.path),
                  FileManager.default.fileExists(atPath: source.fileURL.path)
            else {
                return
            }
            bookmarkAccess.resolutionURLReplacements[source.fileURL] = source.fileURL
        }
        fixture.appState.installWorkspaceRelocationRecovery(
            intent,
            reason: .namespaceChanged,
            actualMovedExpectation: expectation
        )

        let completion = try fixture.appState.reconcileWorkspaceMutationRecovery(id: intent.id)

        guard case .relocation = completion else {
            return XCTFail("Expected relocation rollback reconciliation")
        }
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspect(at: source), expectation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedArchive.appendingPathComponent("draft.md").path
        ))
        XCTAssertEqual(
            try String(contentsOf: fixture.url("archive/occupant.txt"), encoding: .utf8),
            "Replacement"
        )
        XCTAssertTrue(fixture.appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(fixture.appState.indeterminateWorkspaceMutationSessions.isEmpty)
        XCTAssertEqual(fixture.appState.currentDocument.fileURL, source.fileURL)
        XCTAssertEqual(
            fixture.appState.anchoredSessionFileBinding(
                for: fixture.appState.currentDocument
            )?.location,
            source
        )
    }

    func testPendingRecoveryDoesNotAdoptReplacementAfterRestoredSourceParentEscapes()
        throws
    {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        let escapedArchive = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("reverse-archive-\(UUID().uuidString)", isDirectory: true)
        let escapedPosts = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("reverse-posts-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: escapedArchive)
            try? FileManager.default.removeItem(at: escapedPosts)
        }
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        try FileManager.default.moveItem(at: fixture.url("archive"), to: escapedArchive)
        try FileManager.default.createDirectory(
            at: fixture.url("archive"),
            withIntermediateDirectories: false
        )
        bookmarkAccess.resolutionURLReplacements[fixture.url("archive")] =
            escapedArchive
        fixture.appState.installWorkspaceRelocationRecovery(
            intent,
            reason: .namespaceChanged,
            actualMovedExpectation: expectation
        )
        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed

        XCTAssertThrowsError(
            try fixture.appState.reconcileWorkspaceMutationRecovery(id: intent.id)
        )
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspectExact(at: source), expectation)
        XCTAssertNotNil(operationStore.records[intent.id])

        try FileManager.default.moveItem(at: fixture.url("posts"), to: escapedPosts)
        try FileManager.default.createDirectory(
            at: fixture.url("posts"),
            withIntermediateDirectories: false
        )
        try "Foreign".write(to: source.fileURL, atomically: false, encoding: .utf8)
        bookmarkAccess.resolutionURLReplacements[fixture.url("posts")] = escapedPosts
        operationStore.removeError = nil

        XCTAssertThrowsError(
            try fixture.appState.reconcileWorkspaceMutationRecovery(id: intent.id)
        )
        guard case let .relocation(blocked)? =
            fixture.appState.workspaceMutationRecoveries[intent.id]
        else {
            return XCTFail("Expected durable source-slot recovery to remain installed")
        }
        XCTAssertEqual(
            blocked.sourceParentAuthorityLocation?.fileURL.path,
            escapedPosts.appendingPathComponent("draft.md").path
        )
        XCTAssertEqual(
            try String(contentsOf: source.fileURL, encoding: .utf8),
            "Foreign"
        )
        let escapedSource = try WorkspaceFileSystemLocation(
            fileURL: escapedPosts.appendingPathComponent("draft.md")
        )
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: escapedSource),
            expectation
        )
        XCTAssertNotNil(operationStore.records[intent.id])

        try FileManager.default.removeItem(at: source.fileURL)
        bookmarkAccess.redirectExistingBookmarks(
            createdFor: fixture.url("posts"),
            to: escapedPosts
        )
        bookmarkAccess.resolutionURLReplacements[fixture.url("posts")] = nil

        XCTAssertThrowsError(
            try fixture.appState.reconcileWorkspaceMutationRecovery(id: intent.id)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: escapedSource),
            expectation
        )
        XCTAssertNotNil(operationStore.records[intent.id])
        XCTAssertNotNil(fixture.appState.workspaceMutationRecoveries[intent.id])
        XCTAssertFalse(fixture.appState.indeterminateWorkspaceMutationSessions.isEmpty)
    }

    func testRelocationRecoveryDoesNotReleaseWhenHardLinkAliasOccupiesOtherSlot() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        try FileManager.default.linkItem(at: source.fileURL, to: destination.fileURL)
        fixture.appState.installWorkspaceRelocationRecovery(
            intent,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )

        XCTAssertThrowsError(
            try fixture.appState.reconcileWorkspaceMutationRecovery(id: intent.id)
        )

        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspectExact(at: source), expectation)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            expectation
        )
        XCTAssertNotNil(operationStore.records[intent.id])
        XCTAssertNotNil(fixture.appState.workspaceMutationRecoveries[intent.id])
        XCTAssertFalse(fixture.appState.indeterminateWorkspaceMutationSessions.isEmpty)
    }

    func testRestartResolvesEscapedRelocationParentBookmarkAndRestoresSource() throws {
        let firstBookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            recoveryStore: textStore,
            reportedTrashBookmarkAccess: firstBookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        let escapedArchive = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("restart-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: escapedArchive) }
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        try FileManager.default.moveItem(at: fixture.url("archive"), to: escapedArchive)
        try FileManager.default.createDirectory(
            at: fixture.url("archive"),
            withIntermediateDirectories: false
        )
        fixture.appState.installWorkspaceRelocationRecovery(
            intent,
            reason: .namespaceChanged,
            actualMovedExpectation: expectation
        )

        firstBookmarkAccess.resolutionURLReplacements[fixture.url("archive")] =
            escapedArchive
        let escapedItemURL = escapedArchive.appendingPathComponent("draft.md")
        firstBookmarkAccess.resolutionURLReplacements[source.fileURL] = escapedItemURL
        firstBookmarkAccess.onResolve = { _, _ in
            guard !FileManager.default.fileExists(atPath: escapedItemURL.path),
                  FileManager.default.fileExists(atPath: source.fileURL.path)
            else {
                return
            }
            firstBookmarkAccess.resolutionURLReplacements[source.fileURL] = source.fileURL
        }
        let restarted = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            reportedTrashBookmarkAccess: firstBookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        restarted.restoreWorkspaceMutationOperationRecoveryIfNeeded()

        let completion = try restarted.reconcileWorkspaceMutationRecovery(id: intent.id)

        guard case .relocation = completion else {
            return XCTFail("Expected restart relocation rollback reconciliation")
        }
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspect(at: source), expectation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedArchive.appendingPathComponent("draft.md").path
        ))
        XCTAssertNil(operationStore.records[intent.id])
        XCTAssertNil(restarted.workspaceMutationRecoveries[intent.id])
    }

    func testRestartTreatsMissingLegacyRelocationPhaseAsUnknownAndFailClosed() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            recoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: fixture.expectation("posts/draft.md")
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        let record = try XCTUnwrap(operationStore.records[intent.id])
        guard case let .relocation(relocation) = record.payload else {
            return XCTFail("Expected relocation recovery record")
        }
        let legacyRelocation = WorkspaceMutationOperationRecoveryRecord.Relocation(
            sourceRelativePath: relocation.sourceRelativePath,
            destinationRelativePath: relocation.destinationRelativePath,
            expectation: relocation.expectation,
            sourceParentExpectation: relocation.sourceParentExpectation,
            destinationParentExpectation: relocation.destinationParentExpectation,
            sourceParentBookmarkData: relocation.sourceParentBookmarkData,
            sourceParentDisplayURL: relocation.sourceParentDisplayURL,
            sourceLeafName: relocation.sourceLeafName,
            sourceParentAuthorityExpectation:
            relocation.sourceParentAuthorityExpectation,
            destinationParentBookmarkData: relocation.destinationParentBookmarkData,
            destinationParentDisplayURL: relocation.destinationParentDisplayURL,
            destinationLeafName: relocation.destinationLeafName,
            destinationParentAuthorityExpectation:
            relocation.destinationParentAuthorityExpectation,
            relocatedItemBookmarkData: relocation.relocatedItemBookmarkData,
            relocatedItemDisplayURL: relocation.relocatedItemDisplayURL,
            sessionCommitPhase: nil,
            reason: relocation.reason,
            actualMovedExpectation: relocation.actualMovedExpectation
        )
        operationStore.records[intent.id] = record.replacingPayload(
            .relocation(legacyRelocation),
            textRecoveryRecords: record.textRecoveryRecords
        )
        let restarted = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        restarted.restoreWorkspaceMutationOperationRecoveryIfNeeded()
        guard case let .relocation(restored)? =
            restarted.workspaceMutationRecoveries[intent.id]
        else {
            return XCTFail("Expected restored legacy relocation recovery")
        }

        XCTAssertEqual(restored.sessionCommitState, .unknown)
        XCTAssertThrowsError(
            try restarted.reconcileWorkspaceMutationRecovery(id: intent.id)
        )
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: source),
            intent.expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        XCTAssertNotNil(operationStore.records[intent.id])
        XCTAssertNotNil(restarted.workspaceMutationRecoveries[intent.id])
    }

    func testRestartDoesNotReleaseCommittedRelocationWhenItemBookmarkCannotResolve() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            recoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let expectation = try fixture.expectation("posts/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        var intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        let relocatedItemBookmarkData = try XCTUnwrap(intent.relocatedItemBookmarkData)
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        intent.sessionCommitState = .committed
        try fixture.appState.persistWorkspaceMutationRecoveryIntent(.relocation(intent))
        bookmarkAccess.unresolvableBookmarkData.insert(relocatedItemBookmarkData)

        let restarted = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        restarted.restoreWorkspaceMutationOperationRecoveryIfNeeded()
        guard case let .relocation(restored)? =
            restarted.workspaceMutationRecoveries[intent.id]
        else {
            return XCTFail("Expected restored committed relocation recovery")
        }

        XCTAssertEqual(restored.sessionCommitState, .committed)
        XCTAssertNotNil(restored.sourceParentAuthorityLocation)
        XCTAssertNotNil(restored.destinationParentAuthorityLocation)
        XCTAssertNil(restored.relocatedItemAuthorityLocation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            expectation
        )

        XCTAssertThrowsError(
            try restarted.reconcileWorkspaceMutationRecovery(id: intent.id)
        )
        XCTAssertNotNil(operationStore.records[intent.id])
        XCTAssertNotNil(restarted.workspaceMutationRecoveries[intent.id])
        XCTAssertEqual(
            restarted.workspaceMutationReconciliationPrompt?.recoveryID,
            intent.id
        )
        XCTAssertEqual(
            restarted.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            expectation
        )
    }

    func testUnavailableRelocationBookmarkUpdatePreservesExactLeafForRetry() throws {
        let firstBookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        let fixture = try makeFixture(
            files: ["posts/draft.md": "Original"],
            directories: ["posts", "archive"],
            currentPath: "posts/draft.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: firstBookmarkAccess
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("posts/draft.md")
        let destination = try fixture.location("archive/draft.md")
        let plan = try fixture.appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: fixture.expectation("posts/draft.md")
        )
        let intent = try fixture.appState.prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: fixture.parentExpectation("posts/draft.md"),
            destinationParentExpectation: fixture.parentExpectation("archive/draft.md")
        )
        let unavailableBookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        unavailableBookmarkAccess.resolveError = TestWorkspaceMutationRecoveryStoreError.failed
        let restarted = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: unavailableBookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        restarted.restoreWorkspaceMutationOperationRecoveryIfNeeded()
        guard case var .relocation(restored)? =
            restarted.workspaceMutationRecoveries[intent.id]
        else {
            return XCTFail("Expected relocation recovery with unavailable parent bookmark")
        }
        XCTAssertNil(restored.destinationParentAuthorityLocation)
        XCTAssertEqual(restored.destinationLeafName, "draft.md")

        restored.reason = .durabilityFailed
        try restarted.persistWorkspaceMutationRecoveryUpdate(.relocation(restored))

        guard case let .relocation(persisted)? = operationStore.records[intent.id]?.payload else {
            return XCTFail("Expected updated relocation record")
        }
        XCTAssertEqual(persisted.destinationLeafName, "draft.md")
        XCTAssertNotNil(persisted.destinationParentBookmarkData)
    }

    func testOperationRecoveryStaysVisibleAfterSwitchingDocumentsAndBlocksCreation() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Original",
                "other.md": "Other",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let sourceSession = appState.currentDocument
        let otherSession = try fixture.installSession(path: "other.md", storage: .cached)
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )

        appState.setCurrentDocument(otherSession)
        appState.restoreRecoveryPrompt(for: otherSession)

        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .showEditorCopy
        )
        XCTAssertNil(appState.editorImageAssetInserter)
        appState.createWorkspaceFile(named: "blocked.md", inDirectoryID: nil)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.url("blocked.md").path
        ))

        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertTrue(appState.currentDocument === sourceSession)
        let generationBeforeReconciliation = appState.workspaceGeneration
        appState.reconcileCurrentWorkspaceMutationRecovery()
        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertGreaterThan(appState.workspaceGeneration, generationBeforeReconciliation)
    }

    func testKeepEditorCopyPreservesZeroSessionOperationUntilExplicitRelease() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: fixture.location("renamed.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )

        appState.keepCurrentWorkspaceMutationEditorCopy()

        let recovery = try XCTUnwrap(appState.workspaceMutationRecoveries.values.first)
        XCTAssertTrue(recovery.remainingSessions.isEmpty)
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        XCTAssertTrue(appState.detachedSessionURLs.contains(source.fileURL))

        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, source.fileURL)
    }

    func testZeroSessionOperationRecoveryHasGlobalReconciliationAndReleaseFlow() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Open",
                "unopened.md": "Unopened",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("unopened.md")
        let destination = try fixture.location("renamed-unopened.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: fixture.expectation("unopened.md")
        )
        XCTAssertTrue(plan.records.isEmpty)

        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )

        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        XCTAssertEqual(
            appState.workspaceMutationRecoveryBannerPlacement,
            .editor
        )
        XCTAssertThrowsError(try appState.closeWorkspaceForReplacement())
        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertNil(appState.workspaceMutationReconciliationPrompt)
    }

    func testLegacyCreationRecoveryCannotAdoptLexicalDestinationWithoutItemLocator() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Open",
                "created.md": "",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let originalSession = appState.currentDocument
        let destination = try fixture.location("created.md")
        let expectation = try fixture.expectation("created.md")
        appState.installWorkspaceCreationRecovery(
            .init(
                destination: destination,
                reason: .durabilityFailed,
                recoveryState: .unknown,
                createdExpectation: expectation
            ),
            kind: .file
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: appState.currentDocument)?.identity,
            try fixture.expectation("post.md").identity
        )
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            expectation
        )
    }

    func testLegacyCreationRecoveryCannotReplaceRetainedAuthorityWithLexicalDestination()
        throws
    {
        let fixture = try makeFixture(
            files: [
                "post.md": "Open",
                "created.md": "",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let originalSession = appState.currentDocument
        let destination = try fixture.location("created.md")
        let createdExpectation = try fixture.expectation("created.md")
        let artifact = try fixture.location(".plainsong-create-artifact.tmp")
        try "artifact".write(to: artifact.fileURL, atomically: false, encoding: .utf8)
        let artifactExpectation = try WorkspaceNoFollowItemInspector.inspect(at: artifact)
        appState.installWorkspaceCreationRecovery(
            .init(
                destination: destination,
                reason: .rollbackFailed,
                recoveryState: .retained(artifact),
                createdExpectation: createdExpectation,
                recoveryExpectation: artifactExpectation
            ),
            kind: .file
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))

        try FileManager.default.removeItem(at: artifact.fileURL)
        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: appState.currentDocument)?.identity,
            try fixture.expectation("post.md").identity
        )
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            createdExpectation
        )
    }

    func testLegacyFolderCreationRecoveryCannotAdoptExternalPublicationWithoutItemLocator()
        throws
    {
        let fixture = try makeFixture(
            files: ["post.md": "Open"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let destination = try fixture.location("created")
        let artifact = try fixture.location(".plainsong-create-retained-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: artifact.fileURL,
            withIntermediateDirectories: false
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: artifact)
        appState.installWorkspaceCreationRecovery(
            .init(
                destination: destination,
                reason: .durabilityFailed,
                recoveryState: .retained(artifact),
                recoveryExpectation: expectation,
                publicationSource: artifact
            ),
            kind: .folder
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspect(at: artifact),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )

        try FileManager.default.moveItem(at: artifact.fileURL, to: destination.fileURL)
        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.fileURL.path))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspect(at: destination),
            expectation
        )
        XCTAssertNotNil(appState.workspaceMutationReconciliationPrompt)
    }

    func testCreationRecoveryIsReinstalledWhenActivationThrows() throws {
        let fixture = try makeFixture(
            files: [
                "post.md": "Open",
                "created.md": "",
            ],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let originalSession = appState.currentDocument
        let destination = try fixture.location("created.md")
        let expectation = try fixture.expectation("created.md")
        appState.detachedSessionURLs.insert(destination.fileURL)
        appState.installWorkspaceCreationRecovery(
            .init(
                destination: destination,
                reason: .durabilityFailed,
                recoveryState: .unknown,
                createdExpectation: expectation
            ),
            kind: .file
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertEqual(appState.presentedError?.title, "Could Not Reconcile Workspace Item")
    }

    func testCreationRecoveryKeepsUnexpectedPublishedEntryFencedWithoutMutation() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Open"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let destination = try fixture.location("created")
        let publicationSource = try fixture.location(".plainsong-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: publicationSource.fileURL,
            withIntermediateDirectories: false
        )
        let replacementExpectation = try WorkspaceNoFollowItemInspector.inspect(
            at: publicationSource
        )
        try FileManager.default.moveItem(
            at: publicationSource.fileURL,
            to: destination.fileURL
        )
        appState.installWorkspaceCreationRecovery(
            .init(
                destination: destination,
                reason: .rollbackFailed,
                recoveryState: .unknown,
                publicationSource: publicationSource,
                actualPublishedExpectation: replacementExpectation
            ),
            kind: .folder
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: publicationSource.fileURL.path))
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspect(at: destination),
            replacementExpectation
        )
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        guard case let .creation(context)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected retained creation recovery")
        }
        XCTAssertEqual(context.actualPublishedExpectation, replacementExpectation)
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
    }

    func testRelocationRecoveryAtomicallyCommitsProvenDestination() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let expectation = try fixture.expectation("post.md")
        XCTAssertThrowsError(try appState.renameWorkspaceItem(
            at: source,
            to: "renamed.md",
            expecting: expectation,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation
        ))
        operationStore.removeError = nil

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        XCTAssertEqual(session.fileURL, destination.fileURL)
        XCTAssertTrue(appState.sessionCache[destination.fileURL] === session)
        XCTAssertNil(appState.sessionCache[source.fileURL])
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.location,
            destination
        )
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: destination.fileURL), false)
    }

    func testRelocationRecoveryLeavesUnexpectedMovedEntryQuarantinedWithoutMutation() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let expectation = try fixture.expectation("post.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let heldOriginalURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("held-original-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: heldOriginalURL) }
        try FileManager.default.moveItem(at: source.fileURL, to: heldOriginalURL)
        try "Replacement".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let replacementExpectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .rollbackFailed,
            actualMovedExpectation: replacementExpectation
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: destination.fileURL, encoding: .utf8),
            "Replacement"
        )
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        guard case let .relocation(context)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected retained relocation recovery")
        }
        XCTAssertEqual(context.actualMovedExpectation, replacementExpectation)
    }

    func testRelocationRecoveryClearsUnexpectedExpectationAlreadyRestoredAtSource() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let expectation = try fixture.expectation("post.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        let heldOriginalURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("held-original-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: heldOriginalURL) }
        try FileManager.default.moveItem(at: source.fileURL, to: heldOriginalURL)
        try "Replacement".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let replacementExpectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .rollbackFailed,
            actualMovedExpectation: replacementExpectation
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        guard case let .relocation(context)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected retained relocation recovery")
        }
        XCTAssertNil(context.actualMovedExpectation)
        XCTAssertEqual(
            try String(contentsOf: source.fileURL, encoding: .utf8),
            "Replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginalURL.path))
    }

    func testRelocationRecoveryWaitsForPendingEditorSourceWithoutRetiringWriter() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        let writer = appState.editorWriterInstallations[ObjectIdentifier(session)]
        let source = try fixture.location("post.md")
        let destination = try fixture.location("renamed.md")
        let plan = try appState.prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: fixture.expectation("post.md")
        )
        try FileManager.default.moveItem(at: source.fileURL, to: destination.fileURL)
        appState.installWorkspaceRelocationRecovery(
            plan: plan,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            destinationParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            reason: .durabilityFailed
        )
        appState.pendingEditorSourceInstallations[installation] = session

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertEqual(session.fileURL, source.fileURL)
        XCTAssertEqual(
            appState.editorWriterInstallations[ObjectIdentifier(session)],
            writer
        )
        XCTAssertEqual(appState.presentedError?.title, "Could Not Reconcile Workspace Item")
    }

    func testTrashRecoveryDoesNotReleaseWhileExpectedHardLinkRemainsInStaging() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")
        let records = try appState.prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )
        let staging = try fixture.location(".plainsong-trash-hardlink")
        try FileManager.default.linkItem(at: source.fileURL, to: staging.fileURL)
        appState.installWorkspaceTrashRecovery(
            source: source,
            expectation: expectation,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            records: records,
            reason: .rollbackFailed,
            recoveryLocation: staging,
            reportedTrashURL: nil,
            cleanupState: .removalIndeterminate(staging)
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspectExact(at: source), expectation)
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspectExact(at: staging), expectation)
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.isEmpty)
    }

    func testTrashRecoveryDoesNotTreatEquivalentSourceSpellingAsRestored() throws {
        let fixture = try makeFixture(
            files: ["Post.md": "Original"],
            currentPath: "Post.md"
        )
        defer { cleanUp(fixture) }
        let exactSource = try fixture.location("Post.md")
        guard try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(of: exactSource) else {
            throw XCTSkip("Equivalent spelling requires a case-insensitive test volume")
        }
        let appState = fixture.appState
        let equivalentSource = try fixture.location("post.md")
        let expectation = try fixture.expectation("Post.md")
        let records = try appState.prepareWorkspaceTrashRecords(
            source: exactSource,
            expectation: expectation
        )
        appState.installWorkspaceTrashRecovery(
            source: equivalentSource,
            expectation: expectation,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            records: records,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            cleanupState: .notCreated
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertThrowsError(
            try WorkspaceNoFollowItemInspector.inspectExact(at: equivalentSource)
        )
        XCTAssertEqual(try WorkspaceNoFollowItemInspector.inspectExact(at: exactSource), expectation)
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.isEmpty)
    }

    func testDurableRelocationRetargetsPersistentTextRecoveryContext() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let records = try appState.prepareWorkspaceTrashRecords(
            source: fixture.location("post.md"),
            expectation: fixture.expectation("post.md")
        )
        appState.installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        appState.applyDocumentText("Changed before rename", to: session)

        try appState.renameWorkspaceItem(
            at: fixture.location("post.md"),
            to: "renamed.md",
            expecting: fixture.expectation("post.md"),
            sourceParentExpectation: fixture.parentExpectation("post.md")
        )

        let context = try XCTUnwrap(
            appState.workspaceMutationTextRecoveryContexts[ObjectIdentifier(session)]
        )
        XCTAssertEqual(context.originalURL, fixture.url("renamed.md"))
        XCTAssertEqual(fixture.recoveryStore.records[context.recoveryID]?.originalURL, context.originalURL)
    }

    func testTrashRecoveryKeepsUnexpectedStagedEntryFencedWithoutMutation() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")
        let records = try appState.prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )
        let staging = try fixture.location(".plainsong-trash-\(UUID().uuidString)")
        let replacement = try fixture.location("replacement.md")
        try "Replacement".write(to: replacement.fileURL, atomically: false, encoding: .utf8)
        let replacementExpectation = try WorkspaceNoFollowItemInspector.inspect(at: replacement)
        try FileManager.default.moveItem(at: replacement.fileURL, to: staging.fileURL)
        appState.installWorkspaceTrashRecovery(
            source: source,
            expectation: expectation,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            records: records,
            reason: .rollbackFailed,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            cleanupState: .removalIndeterminate(staging),
            actualStagedExpectation: replacementExpectation
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.fileURL.path))

        let heldOriginalURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("held-trash-original-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: heldOriginalURL) }
        try FileManager.default.moveItem(at: source.fileURL, to: heldOriginalURL)
        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertEqual(
            try String(contentsOf: staging.fileURL, encoding: .utf8),
            "Replacement"
        )
        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        guard case let .trash(context)? = appState.workspaceMutationRecoveries.values.first else {
            return XCTFail("Expected retained Trash recovery")
        }
        XCTAssertEqual(context.actualStagedExpectation, replacementExpectation)
        XCTAssertEqual(context.actualStagedEntryRecoveryLocation, source)
        guard case let .removalIndeterminate(journaledStaging) = context.cleanupState else {
            return XCTFail("Expected retained indeterminate staging slot")
        }
        XCTAssertEqual(journaledStaging, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginalURL.path))
    }

    func testTrashRecoveryKeepsWrongEntryInJournaledSlotAfterIndeterminateRestore() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")
        let records = try appState.prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )
        let staging = try fixture.location(".plainsong-trash-\(UUID().uuidString)")
        appState.installWorkspaceTrashRecovery(
            source: source,
            expectation: expectation,
            sourceParentExpectation: fixture.rootAuthority.directoryMutationExpectation,
            records: records,
            reason: .rollbackFailed,
            recoveryLocation: staging,
            reportedTrashURL: nil,
            cleanupState: .removalIndeterminate(staging)
        )
        guard case let .trash(installedContext)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected retained Trash recovery")
        }

        let heldOriginalURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("held-trash-original-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: heldOriginalURL) }
        try FileManager.default.moveItem(at: source.fileURL, to: heldOriginalURL)
        try "Replacement".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let replacementExpectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let outcome: WorkspaceItemMutationOutcome<Void> = .movedButIndeterminate(.init(
            relocation: .init(
                source: staging,
                destination: source,
                expectation: expectation
            ),
            reason: .namespaceChanged,
            preparedCommit: nil,
            actualMovedExpectation: replacementExpectation
        ))

        XCTAssertThrowsError(
            try appState.reconcileWorkspaceTrashRecoveryRelocationOutcome(
                outcome,
                context: installedContext,
                recoveryLocation: staging
            )
        )
        guard case let .trash(indeterminateContext)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected indeterminate Trash recovery")
        }
        XCTAssertEqual(
            indeterminateContext.actualStagedExpectation,
            replacementExpectation
        )
        XCTAssertEqual(
            indeterminateContext.actualStagedEntryRecoveryLocation,
            staging
        )

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.workspaceMutationRecoveries.isEmpty)
        guard case let .trash(reconciledContext)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected fenced Trash recovery")
        }
        XCTAssertEqual(
            reconciledContext.actualStagedExpectation,
            replacementExpectation
        )
        XCTAssertEqual(reconciledContext.actualStagedEntryRecoveryLocation, staging)
        XCTAssertEqual(
            try String(contentsOf: source.fileURL, encoding: .utf8),
            "Replacement"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.fileURL.path))
        XCTAssertFalse(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        guard case let .removalIndeterminate(journaledStaging) =
            reconciledContext.cleanupState
        else {
            return XCTFail("Expected retained indeterminate staging slot")
        }
        XCTAssertEqual(journaledStaging, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginalURL.path))
    }

    func testTrashRecoveryWithProvenReportedTrashPreservesNewInputAsDetachedCopy() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let source = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")
        let sourceParentExpectation = try fixture.parentExpectation("post.md")
        let records = try appState.prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )
        appState.installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        try appState.persistWorkspaceMutationTextRecovery(for: session)
        let recoveryIntent = try appState.prepareWorkspaceTrashRecoveryIntent(
            WorkspaceTrashRecoveryContext(
                id: UUID(),
                source: source,
                expectation: expectation,
                sourceParentExpectation: sourceParentExpectation,
                reason: .namespaceChanged,
                recoveryLocation: nil,
                reportedTrashURL: nil,
                reportedTrashBookmarkData: nil,
                reportedTrashAuthorityLocation: nil,
                cleanupState: .removed,
                actualStagedExpectation: nil,
                actualStagedEntryRecoveryLocation: nil,
                records: records,
                remainingSessionIDs: Set(records.map { ObjectIdentifier($0.session) })
            )
        )
        let reportedTrashURL = fixture.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("reported-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reportedTrashURL) }
        try FileManager.default.moveItem(at: source.fileURL, to: reportedTrashURL)
        bookmarkAccess.redirectExistingBookmarks(
            createdFor: source.fileURL,
            to: reportedTrashURL
        )
        let committedRecovery = try appState.prepareWorkspaceTrashCommittedRecovery(
            recoveryIntent,
            reportedTrashURL: reportedTrashURL
        )
        appState.installWorkspaceTrashRecovery(
            committedRecovery,
            reason: .recyclerFailed,
            recoveryLocation: nil,
            reportedTrashURL: reportedTrashURL,
            cleanupState: .removed,
            actualStagedExpectation: nil
        )
        guard case let .trash(recovery)? =
            appState.workspaceMutationRecoveries.values.first
        else {
            return XCTFail("Expected retained Trash recovery")
        }
        XCTAssertNotNil(recovery.expectedItemBookmarkData)
        XCTAssertNotNil(recovery.reportedTrashBookmarkData)
        XCTAssertNotNil(recovery.reportedTrashAuthorityLocation)
        appState.applyDocumentText("Typed after uncertain Trash", to: session)

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertTrue(appState.indeterminateWorkspaceMutationSessions.isEmpty)
        XCTAssertTrue(appState.detachedSessionURLs.contains(source.fileURL))
        XCTAssertEqual(session.text, "Typed after uncertain Trash")
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, source.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
    }

    func testRestartNeverUsesReportedTrashDisplayURLWithoutBookmarkAuthority() throws {
        let fixture = try makePersistedReportedTrashFixture(bookmarkData: nil)
        defer { fixture.cleanUp() }
        let bookmarkAccess = RecordingReportedTrashBookmarkAccess()
        bookmarkAccess.resolutionsByBookmark[fixture.sourceParentBookmarkData] = .init(
            fileURL: fixture.rootURL,
            isStale: false
        )
        bookmarkAccess.resolution = .init(
            fileURL: fixture.reportedTrashURL,
            isStale: false
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [fixture.record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard case let .trash(context)? =
            appState.workspaceMutationRecoveries[fixture.record.id]
        else {
            return XCTFail("Expected restored Trash recovery")
        }
        XCTAssertEqual(context.reportedTrashURL, fixture.reportedTrashURL)
        XCTAssertNil(context.reportedTrashAuthorityLocation)
        XCTAssertEqual(bookmarkAccess.resolveCallCount, 1)
        XCTAssertThrowsError(
            try appState.reconcileWorkspaceMutationRecovery(id: fixture.record.id)
        )
        XCTAssertNotNil(operationStore.records[fixture.record.id])
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
    }

    func testRestartKeepsTrashRecoveryWhenReportedBookmarkCannotResolve() throws {
        let fixture = try makePersistedReportedTrashFixture(
            bookmarkData: Data("unavailable-bookmark".utf8)
        )
        defer { fixture.cleanUp() }
        let bookmarkAccess = RecordingReportedTrashBookmarkAccess()
        bookmarkAccess.resolutionsByBookmark[fixture.sourceParentBookmarkData] = .init(
            fileURL: fixture.rootURL,
            isStale: false
        )
        bookmarkAccess.resolveError = TestWorkspaceMutationRecoveryStoreError.failed
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [fixture.record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard case let .trash(context)? =
            appState.workspaceMutationRecoveries[fixture.record.id]
        else {
            return XCTFail("Expected restored Trash recovery")
        }
        XCTAssertNil(context.reportedTrashAuthorityLocation)
        XCTAssertEqual(bookmarkAccess.resolveCallCount, 3)
        XCTAssertThrowsError(
            try appState.reconcileWorkspaceMutationRecovery(id: fixture.record.id)
        )
        XCTAssertNotNil(operationStore.records[fixture.record.id])
    }

    func testRestartRejectsReportedTrashBookmarkWithMismatchedIdentity() throws {
        let fixture = try makePersistedReportedTrashFixture(
            bookmarkData: Data("mismatched-bookmark".utf8)
        )
        defer { fixture.cleanUp() }
        let replacementURL = fixture.reportedTrashURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: replacementURL) }
        try "Replacement".write(to: replacementURL, atomically: false, encoding: .utf8)
        let bookmarkAccess = RecordingReportedTrashBookmarkAccess()
        bookmarkAccess.resolutionsByBookmark[fixture.sourceParentBookmarkData] = .init(
            fileURL: fixture.rootURL,
            isStale: false
        )
        bookmarkAccess.resolution = .init(
            fileURL: replacementURL,
            isStale: false
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [fixture.record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard case let .trash(context)? =
            appState.workspaceMutationRecoveries[fixture.record.id]
        else {
            return XCTFail("Expected restored Trash recovery")
        }
        XCTAssertNil(context.reportedTrashAuthorityLocation)
        XCTAssertThrowsError(
            try appState.reconcileWorkspaceMutationRecovery(id: fixture.record.id)
        )
        XCTAssertNotNil(operationStore.records[fixture.record.id])
    }

    func testRestartRefreshesStaleReportedTrashBookmarkAndUsesRetainedAuthority() throws {
        let originalBookmark = Data("stale-bookmark".utf8)
        let refreshedBookmark = Data("refreshed-bookmark".utf8)
        let fixture = try makePersistedReportedTrashFixture(
            bookmarkData: originalBookmark
        )
        defer { fixture.cleanUp() }
        let bookmarkAccess = RecordingReportedTrashBookmarkAccess()
        bookmarkAccess.resolutionsByBookmark[fixture.sourceParentBookmarkData] = .init(
            fileURL: fixture.rootURL,
            isStale: false
        )
        bookmarkAccess.resolutionsByBookmark[originalBookmark] = .init(
            fileURL: fixture.reportedTrashURL,
            isStale: true
        )
        bookmarkAccess.resolutionsByBookmark[refreshedBookmark] = .init(
            fileURL: fixture.reportedTrashURL,
            isStale: false
        )
        bookmarkAccess.bookmarkData = refreshedBookmark
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [fixture.record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard case let .trash(context)? =
            appState.workspaceMutationRecoveries[fixture.record.id]
        else {
            return XCTFail("Expected restored Trash recovery")
        }
        XCTAssertNotNil(context.reportedTrashAuthorityLocation)
        XCTAssertEqual(context.reportedTrashBookmarkData, refreshedBookmark)
        XCTAssertNotNil(context.expectedItemAuthorityLocation)
        XCTAssertEqual(context.expectedItemBookmarkData, refreshedBookmark)
        guard case let .trash(persisted)? =
            operationStore.records[fixture.record.id]?.payload
        else {
            return XCTFail("Expected persisted Trash operation")
        }
        XCTAssertEqual(persisted.reportedTrashBookmarkData, refreshedBookmark)
        XCTAssertEqual(persisted.expectedItemBookmarkData, refreshedBookmark)
        XCTAssertEqual(bookmarkAccess.makeCallCount, 2)

        _ = try appState.reconcileWorkspaceMutationRecovery(id: fixture.record.id)

        XCTAssertNil(operationStore.records[fixture.record.id])
        XCTAssertNil(appState.workspaceMutationRecoveries[fixture.record.id])
    }

    func testStaleReportedTrashBookmarkRefreshFailureRemainsUnresolvedAndFenced() throws {
        let originalBookmark = Data("stale-bookmark".utf8)
        let fixture = try makePersistedReportedTrashFixture(
            bookmarkData: originalBookmark
        )
        defer { fixture.cleanUp() }
        let bookmarkAccess = RecordingReportedTrashBookmarkAccess()
        bookmarkAccess.resolutionsByBookmark[fixture.sourceParentBookmarkData] = .init(
            fileURL: fixture.rootURL,
            isStale: false
        )
        bookmarkAccess.resolution = .init(
            fileURL: fixture.reportedTrashURL,
            isStale: true
        )
        bookmarkAccess.makeError = TestWorkspaceMutationRecoveryStoreError.failed
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [fixture.record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard case let .trash(context)? =
            appState.workspaceMutationRecoveries[fixture.record.id]
        else {
            return XCTFail("Expected restored Trash recovery")
        }
        XCTAssertNil(context.reportedTrashAuthorityLocation)
        XCTAssertNil(context.expectedItemAuthorityLocation)
        XCTAssertEqual(context.reportedTrashBookmarkData, originalBookmark)
        XCTAssertEqual(context.expectedItemBookmarkData, originalBookmark)
        guard case let .trash(persisted)? =
            operationStore.records[fixture.record.id]?.payload
        else {
            return XCTFail("Expected persisted Trash operation")
        }
        XCTAssertEqual(persisted.reportedTrashBookmarkData, originalBookmark)

        XCTAssertThrowsError(
            try appState.reconcileWorkspaceMutationRecovery(id: fixture.record.id)
        )

        XCTAssertNotNil(operationStore.records[fixture.record.id])
        XCTAssertNotNil(appState.workspaceMutationRecoveries[fixture.record.id])
    }

    func testRestoredPersistentRecoveryIsDetachedAndNeverOwnsReplacementPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoredWorkspaceMutationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("post.md")
        let saveCopyURL = root.appendingPathComponent("recovered.md")
        try "Replacement".write(to: originalURL, atomically: false, encoding: .utf8)
        let record = WorkspaceMutationTextRecoveryRecord(
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Recovered e\u{0301} 👩🏽‍💻",
            revision: 9,
            reason: .trash
        )
        let store = RecordingWorkspaceMutationTextRecoveryStore(records: [record])
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: store,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreWorkspaceMutationTextRecoveryIfNeeded()

        let session = appState.currentDocument
        XCTAssertEqual(session.text, record.source)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.detachedSessionURLs.contains(originalURL))
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, originalURL)
        XCTAssertNil(appState.anchoredSessionFileBinding(for: session))
        guard case .some(.unavailable(fileURL: _)) =
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)]
        else {
            return XCTFail("Restored recovery must not recapture the original URL")
        }

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: originalURL)
        )
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "Replacement")
        XCTAssertEqual(session.text, record.source)
        XCTAssertTrue(session.isDirty)

        try appState.saveDetachedCurrentDocument(to: saveCopyURL)

        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "Replacement")
        XCTAssertEqual(try String(contentsOf: saveCopyURL, encoding: .utf8), record.source)
        XCTAssertEqual(session.fileURL, saveCopyURL)
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSaveCopyCleanupFailureRequiresExplicitPerRecordQuarantine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveCopyRecoveryCleanup")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("missing.md")
        let saveCopyURL = root.appendingPathComponent("saved.md")
        let record = WorkspaceMutationTextRecoveryRecord(
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Recovered e\u{0301} 👩🏽‍💻",
            revision: 7,
            reason: .trash
        )
        let store = RecordingWorkspaceMutationTextRecoveryStore(records: [record])
        store.removeRecordBeforeThrow = true
        store.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: store,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
        let session = appState.currentDocument

        try appState.saveDetachedCurrentDocument(to: saveCopyURL)

        XCTAssertEqual(try String(contentsOf: saveCopyURL, encoding: .utf8), record.source)
        XCTAssertEqual(session.fileURL, saveCopyURL)
        XCTAssertFalse(session.isDirty)
        let sessionIdentity = ObjectIdentifier(session)
        XCTAssertTrue(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]?
                .requiresExplicitStopTracking == true
        )
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt,
            WorkspaceMutationReconciliationPrompt(
                recoveryID: record.id,
                operation: .textRecovery,
                sourceURL: originalURL,
                secondaryAction: .stopTracking
            )
        )
        XCTAssertEqual(store.records[record.id]?.source, record.source)
        XCTAssertEqual(store.removeCallCount, 1)

        XCTAssertFalse(appState.prepareForTermination())
        XCTAssertEqual(store.removeCallCount, 1)

        store.recordQuarantineError = TestWorkspaceMutationRecoveryStoreError.failed
        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertEqual(appState.presentedError?.title, "Could Not Stop Tracking Editor Recovery")
        XCTAssertNotNil(
            appState.workspaceMutationTextRecoveryContexts[sessionIdentity]
        )
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        XCTAssertFalse(appState.prepareForTermination())

        store.recordQuarantineError = nil
        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertEqual(store.recordQuarantineCallCount, 2)
        XCTAssertEqual(store.quarantinedRecords[record.id]?.source, record.source)
        XCTAssertNil(store.records[record.id])
        XCTAssertNil(appState.workspaceMutationTextRecoveryContexts[sessionIdentity])
        XCTAssertNil(appState.workspaceMutationTextRecoverySessions[record.id])
        XCTAssertNil(appState.workspaceMutationReconciliationPrompt)
        XCTAssertTrue(appState.prepareForTermination())
    }

    func testSwitchingAwayFromDetachedRecoveryKeepsGlobalNavigationBackToIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavigableWorkspaceMutationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("post.md")
        let otherURL = root.appendingPathComponent("other.md")
        let record = WorkspaceMutationTextRecoveryRecord(
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Recovered source",
            revision: 3,
            reason: .trash
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(records: [record]),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
        let recoverySession = appState.currentDocument
        let otherSession = DocumentSession(
            text: "Other",
            url: otherURL,
            fileKind: .markdown
        )

        appState.setCurrentDocument(otherSession)
        appState.restoreRecoveryPrompt(for: otherSession)

        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.operation,
            .textRecovery
        )
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .showEditorCopy
        )
        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertTrue(appState.currentDocument === recoverySession)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, originalURL)
    }

    func testStartupRestoresOperationAndNewestTextRecoveryBeforeSkippingLastOpened() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationRecoveryStartup")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let textID = UUID()
        let originalURL = root.appendingPathComponent("post.md")
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            id: textID,
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Bundled",
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            reason: .indeterminateMutation
        )
        let standaloneText = WorkspaceMutationTextRecoveryRecord(
            id: textID,
            originalURL: originalURL,
            fileKind: .markdown,
            source: "Newest standalone",
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 2),
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore(
            records: [standaloneText]
        )
        let lastOpenedStore = RecordingLastOpenedFileStore(
            restoredURL: root.appendingPathComponent("last-opened.md")
        )
        let appState = AppState(
            lastOpenedFileStore: lastOpenedStore,
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: true
        )

        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(lastOpenedStore.restoreCallCount, 0)
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
        XCTAssertEqual(appState.currentDocument.text, standaloneText.source)
        XCTAssertEqual(
            appState.workspaceMutationTextRecoveryContexts[
                ObjectIdentifier(appState.currentDocument)
            ]?.recoveryID,
            textID
        )
    }

    func testOperationInstallAtomicallyBundlesInitialTextRecoverySnapshot() throws {
        let fixture = try makeFixture(
            files: ["post.md": "Initial editor source"],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        let source = try fixture.location("post.md")
        let expectation = try fixture.expectation("post.md")
        let records = try fixture.appState.prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )

        try fixture.appState.installWorkspaceTrashRecovery(
            source: source,
            expectation: expectation,
            sourceParentExpectation: fixture.parentExpectation("post.md"),
            records: records,
            reason: .recyclerFailed,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            cleanupState: .notCreated
        )

        let persisted = try XCTUnwrap(
            fixture.operationRecoveryStore.records.values.first
        )
        guard case .trash = persisted.payload else {
            return XCTFail("Expected a Trash operation bundle")
        }
        XCTAssertEqual(persisted.textRecoveryRecords.count, 1)
        XCTAssertEqual(
            persisted.textRecoveryRecords.first?.source,
            fixture.appState.currentDocument.text
        )
        XCTAssertEqual(
            persisted.textRecoveryRecords.first?.revision,
            fixture.appState.currentDocument.version
        )
    }

    func testMultipleOperationStartupPromotesAllTextAndSelectsDeterministically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipleOperationRecoveryStartup")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("a.md"),
            fileKind: .markdown,
            source: "A recovery",
            revision: 1,
            reason: .indeterminateMutation
        )
        let zText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("z.md"),
            fileKind: .markdown,
            source: "Z recovery",
            revision: 1,
            reason: .indeterminateMutation
        )
        let zOperation = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            destinationRelativePath: "z.md",
            textRecoveryRecords: [zText]
        )
        let aOperation = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            destinationRelativePath: "a.md",
            textRecoveryRecords: [aText]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(
                records: [zOperation, aOperation]
            ),
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.sourceURL.lastPathComponent,
            "a.md"
        )
        XCTAssertEqual(textStore.records[aText.id]?.source, aText.source)
        XCTAssertEqual(textStore.records[zText.id]?.source, zText.source)
    }

    func testStartupRebuildsMatchingOperationAsZeroSessionContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchingOperationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try makeCreationOperationRecoveryRecord(rootURL: root)
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        guard let restoredRecovery = appState.workspaceMutationRecoveries[record.id],
              case .creation = restoredRecovery
        else {
            return XCTFail("Expected a restored creation recovery")
        }
        XCTAssertTrue(
            appState.workspaceMutationRecoveries[record.id]?.remainingSessions.isEmpty == true
        )
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        XCTAssertFalse(appState.hasOpenDocument)
        XCTAssertEqual(
            appState.workspaceMutationRecoveryBannerPlacement,
            .global
        )

        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertNil(operationStore.records[record.id])
        XCTAssertEqual(
            appState.workspaceMutationRecoveryBannerPlacement,
            .hidden
        )
    }

    func testPlannedCreationRestartReleasesOnlyWhenEveryCandidateIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingPlannedCreation")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRelativePath = ".plainsong-create-dir-\(UUID().uuidString.lowercased())"
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "images",
                publicationPhase: .planned,
                kind: .folder,
                isPlanned: true,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath
            ),
            bookmarkAccess: bookmarkAccess
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        guard case let .creation(restored)? =
            appState.workspaceMutationRecoveries[record.id]
        else {
            return XCTFail("Expected planned creation recovery")
        }
        XCTAssertEqual(restored.publicationState, .planned)
        XCTAssertNotNil(restored.destinationParentAuthorityLocation)

        _ = try appState.reconcileWorkspaceMutationRecovery(id: record.id)

        XCTAssertNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNil(operationStore.records[record.id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("images").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(stagingRelativePath).path
        ))
    }

    func testPreparedCreationRestartRetainsRootStagingArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCreationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let staging = try authority.location(relativePath: stagingRelativePath)
        try "Prepared".write(to: staging.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: staging)
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "created.md",
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: expectation,
                recoveryState: .retained(relativePath: stagingRelativePath),
                recoveryExpectation: expectation,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: staging.fileURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        guard case let .creation(recovery)? =
            appState.workspaceMutationRecoveries[record.id]
        else {
            return XCTFail("Prepared staging must remain fenced")
        }
        XCTAssertEqual(recovery.publicationState, .prepared)
        XCTAssertEqual(recovery.createdItemAuthorityLocation?.fileURL, staging.fileURL)
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: staging),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("created.md").path
        ))
        XCTAssertFalse(appState.hasOpenDocument)
    }

    func testPreparedCreationRestartAdoptsBookmarkProvenPublishedItem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedPublishedCreationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let destination = try authority.location(relativePath: "created.md")
        try "Published".write(
            to: destination.fileURL,
            atomically: false,
            encoding: .utf8
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: destination)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let stagingURL = root.appendingPathComponent(stagingRelativePath)
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: destination.relativePath,
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: expectation,
                recoveryState: .retained(relativePath: stagingRelativePath),
                recoveryExpectation: expectation,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: destination.fileURL,
                createdItemDisplayURL: stagingURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        _ = try appState.reconcileWorkspaceMutationRecovery(id: record.id)

        XCTAssertNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNil(operationStore.records[record.id])
        XCTAssertEqual(appState.currentDocument.fileURL, destination.fileURL)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: appState.currentDocument)?.identity,
            expectation.identity
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testCommittedCreationRemoveFailureReconcilesAfterRestart() throws {
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.removeRecordBeforeThrow = true
        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore,
            reportedTrashBookmarkAccess: bookmarkAccess
        )
        defer { cleanUp(fixture) }
        operationStore.onUpsert = { record in
            guard case let .creation(context) = record.payload,
                  context.publicationPhase == .prepared,
                  let stagingPath = context.publicationSourceRelativePath
            else {
                return
            }
            bookmarkAccess.resolutionURLReplacements[fixture.url(stagingPath)] =
                fixture.url("created.md")
        }

        fixture.appState.createWorkspaceFile(named: "created.md", inDirectoryID: nil)

        let record = try XCTUnwrap(operationStore.records.values.first)
        guard case let .creation(committed) = record.payload else {
            return XCTFail("Expected committed creation cleanup record")
        }
        XCTAssertEqual(committed.publicationPhase, .committedCleanup)
        XCTAssertNotNil(committed.destinationParentBookmarkData)
        XCTAssertNotNil(committed.createdItemBookmarkData)
        XCTAssertNotNil(
            operationStore.records[record.id],
            "release must repair the committed journal after delete-before-throw"
        )
        XCTAssertEqual(fixture.appState.currentDocument.fileURL, fixture.url("created.md"))
        operationStore.removeRecordBeforeThrow = false
        operationStore.removeError = nil

        let restarted = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        restarted.restoreLastOpenedFileIfNeeded()
        restarted.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertNil(restarted.workspaceMutationRecoveries[record.id])
        XCTAssertNil(operationStore.records[record.id])
        XCTAssertEqual(restarted.currentDocument.fileURL, fixture.url("created.md"))
        XCTAssertNotNil(restarted.anchoredSessionFileBinding(for: restarted.currentDocument))
    }

    func testPreparedCreationParentEscapeAfterPublishKeepsItemAuthorityFenced()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapedPreparedCreation")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationParentURL = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let staging = try authority.location(relativePath: stagingRelativePath)
        try "Prepared".write(to: staging.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: staging)
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "drafts/created.md",
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: expectation,
                recoveryState: .retained(relativePath: stagingRelativePath),
                recoveryExpectation: expectation,
                publicationSourceRelativePath: stagingRelativePath,
                destinationParentURL: destinationParentURL,
                createdItemBookmarkURL: staging.fileURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        let heldOriginalParent = root.appendingPathComponent(
            "held-original-drafts",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: destinationParentURL,
            to: heldOriginalParent
        )
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let publishedURL = destinationParentURL.appendingPathComponent("created.md")
        try FileManager.default.moveItem(at: staging.fileURL, to: publishedURL)
        let escapedParent = root.deletingLastPathComponent().appendingPathComponent(
            "escaped-created-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: escapedParent) }
        try FileManager.default.moveItem(at: destinationParentURL, to: escapedParent)
        let escapedItemURL = escapedParent.appendingPathComponent("created.md")
        bookmarkAccess.resolutionURLReplacements[destinationParentURL] = heldOriginalParent
        bookmarkAccess.resolutionURLReplacements[staging.fileURL] = escapedItemURL
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        guard case let .creation(recovery)? =
            appState.workspaceMutationRecoveries[record.id]
        else {
            return XCTFail("Escaped created item must remain recoverable")
        }
        XCTAssertEqual(recovery.publicationState, .prepared)
        XCTAssertEqual(
            recovery.createdItemAuthorityLocation?.fileURL.path,
            escapedItemURL.path
        )
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(
                at: WorkspaceFileSystemLocation(fileURL: escapedItemURL)
            ),
            expectation
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("drafts/created.md").path
        ))
        XCTAssertFalse(appState.hasOpenDocument)
    }

    func testCommittedCreationWithUnresolvedItemBookmarkNeverActivatesOrReleases()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnresolvedCommittedCreation")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let destination = try authority.location(relativePath: "created.md")
        try "Created".write(to: destination.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: destination)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: destination.relativePath,
                publicationPhase: .committedCleanup,
                isPlanned: false,
                expectedCreatedItem: expectation,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: destination.fileURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        guard case let .creation(context) = record.payload else {
            return XCTFail("Expected creation payload")
        }
        try bookmarkAccess.unresolvableBookmarkData.insert(
            XCTUnwrap(context.createdItemBookmarkData)
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        guard case let .creation(recovery)? =
            appState.workspaceMutationRecoveries[record.id]
        else {
            return XCTFail("Unresolved item locator must keep recovery fenced")
        }
        XCTAssertTrue(recovery.createdItemAuthorityIsUnresolved)
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertFalse(appState.hasOpenDocument)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(at: destination),
            expectation
        )
    }

    func testCommittedCreationParentEscapeAfterPreparedReadDoesNotCommitActivation()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreationActivationProofEscape")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parentURL = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let destination = try authority.location(relativePath: "drafts/created.md")
        try "Created".write(to: destination.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: destination)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: destination.relativePath,
                publicationPhase: .committedCleanup,
                isPlanned: false,
                expectedCreatedItem: expectation,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath,
                destinationParentURL: parentURL,
                createdItemBookmarkURL: destination.fileURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        guard case let .creation(durableCreation) = record.payload else {
            return XCTFail("Expected creation payload")
        }
        let parentBookmarkData = try XCTUnwrap(
            durableCreation.destinationParentBookmarkData
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        let escapedParent = root.deletingLastPathComponent().appendingPathComponent(
            "escaped-activation-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: escapedParent) }
        let escapedItemURL = escapedParent.appendingPathComponent("created.md")
        var parentResolveCount = 0
        bookmarkAccess.onResolve = { _, bookmarkData in
            guard bookmarkData == parentBookmarkData else { return }
            parentResolveCount += 1
            guard parentResolveCount == 3 else { return }
            try FileManager.default.moveItem(at: parentURL, to: escapedParent)
            bookmarkAccess.resolutionURLReplacements[parentURL] = escapedParent
            bookmarkAccess.resolutionURLReplacements[destination.fileURL] = escapedItemURL
        }

        appState.reconcileCurrentWorkspaceMutationRecovery()

        guard case let .creation(recovery)? =
            appState.workspaceMutationRecoveries[record.id]
        else {
            return XCTFail("Final authority failure must retain committed recovery")
        }
        XCTAssertEqual(recovery.publicationState, .committed)
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertNil(appState.currentDocument.fileURL)
        XCTAssertTrue(appState.sessionCache.isEmpty)
        XCTAssertNil(appState.anchoredSessionFileBinding(for: appState.currentDocument))
        XCTAssertTrue(appState.editorImageAssetDocumentAuthorities.isEmpty)
        XCTAssertEqual(
            try WorkspaceNoFollowItemInspector.inspectExact(
                at: WorkspaceFileSystemLocation(fileURL: escapedItemURL)
            ),
            expectation
        )
    }

    func testDurableUnsupportedCreationRestartReconcilesWithoutActivationOrFence()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnsupportedCreationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let destination = try authority.location(relativePath: "notes.txt")
        try Data().write(to: destination.fileURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: destination)
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: destination.relativePath,
                publicationPhase: .committedCleanup,
                isPlanned: false,
                expectedCreatedItem: expectation,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: destination.fileURL
            ),
            bookmarkAccess: bookmarkAccess
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertFalse(appState.hasOpenDocument)
        XCTAssertTrue(appState.workspaceMutationRecoveries.isEmpty)
        XCTAssertNil(operationStore.records[record.id])
        XCTAssertNil(appState.workspaceMutationReconciliationPrompt)
        XCTAssertTrue(appState.workspaceMutationWriteFences.isEmpty)
        XCTAssertNil(appState.presentedError)
        XCTAssertTrue(appState.prepareForTermination())
    }

    func testPlannedCreationRestartFailsClosedForAnyCandidateOccupant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OccupiedPlannedCreation")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRelativePath = ".plainsong-create-dir-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(stagingRelativePath),
            withIntermediateDirectories: false
        )
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "images",
                publicationPhase: .planned,
                kind: .folder,
                isPlanned: true,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath
            ),
            bookmarkAccess: bookmarkAccess
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertEqual(
            appState.presentedError?.title,
            "Could Not Reconcile Workspace Item"
        )
    }

    func testPlannedCreationRestartFailsClosedWhenCandidateParentIdentityChanged()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplacedPlannedCreationParent")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let drafts = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let originalParentExpectation = try WorkspaceNoFollowItemInspector.inspect(
            at: authority.location(relativePath: "drafts")
        )
        let stagingRelativePath =
            ".plainsong-create-dir-\(UUID().uuidString.lowercased())"
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let record = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "drafts/images",
                publicationPhase: .planned,
                kind: .folder,
                isPlanned: true,
                recoveryState: .none,
                publicationSourceRelativePath: stagingRelativePath,
                destinationParentURL: drafts,
                destinationParentExpectation: originalParentExpectation
            ),
            bookmarkAccess: bookmarkAccess
        )
        let retainedDrafts = root.appendingPathComponent(
            "retained-drafts",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: drafts,
            to: retainedDrafts
        )
        try FileManager.default.createDirectory(
            at: drafts,
            withIntermediateDirectories: false
        )
        bookmarkAccess.resolutionURLReplacements[drafts] = retainedDrafts
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        appState.reconcileCurrentWorkspaceMutationRecovery()

        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNotNil(operationStore.records[record.id])
        XCTAssertEqual(
            appState.presentedError?.title,
            "Could Not Reconcile Workspace Item"
        )
    }

    func testBundleOnlyTextIsPromotedBeforeStopTrackingAndSurvivesSecondRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledTextPromotion")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("post.md"),
            fileKind: .markdown,
            source: "Bundle-only source",
            revision: 4,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let firstLaunch = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )

        firstLaunch.restoreLastOpenedFileIfNeeded()
        firstLaunch.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertNil(operationStore.records[operationRecord.id])
        XCTAssertEqual(textStore.records[bundledText.id]?.source, bundledText.source)

        let secondLaunch = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        secondLaunch.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(secondLaunch.currentDocument.text, bundledText.source)
        XCTAssertTrue(secondLaunch.currentDocument.isDirty)
    }

    func testRestoredLogicalRevisionAdvancesPastBundledRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoredLogicalRecoveryRevision")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("post.md"),
            fileKind: .markdown,
            source: "Revision nine",
            revision: 9,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let firstLaunch = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        firstLaunch.restoreLastOpenedFileIfNeeded()
        firstLaunch.applyDocumentText("Edited after restart", to: firstLaunch.currentDocument)
        try firstLaunch.persistWorkspaceMutationTextRecovery(
            for: firstLaunch.currentDocument
        )

        XCTAssertEqual(textStore.records[bundledText.id]?.revision, 10)

        let secondLaunch = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        secondLaunch.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(secondLaunch.currentDocument.text, "Edited after restart")
    }

    func testAuditAMultiSessionStandaloneFailureFallsBackWithoutDroppingSibling() async throws {
        let fixture = try makeFixture(
            files: [
                "a.md": "A original",
                "b.md": "B original",
            ],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let sessionA = appState.currentDocument
        let sessionB = try fixture.installSession(path: "b.md", storage: .cached)
        appState.installWorkspaceMutationTextRecovery(
            for: sessionA,
            originalURL: fixture.url("a.md"),
            reason: .indeterminateMutation
        )
        appState.installWorkspaceMutationTextRecovery(
            for: sessionB,
            originalURL: fixture.url("b.md"),
            reason: .indeterminateMutation
        )
        let initialA = try XCTUnwrap(
            appState.workspaceMutationTextRecoveryRecord(for: sessionA)
        )
        let initialB = try XCTUnwrap(
            appState.workspaceMutationTextRecoveryRecord(for: sessionB)
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: fixture.rootURL,
            textRecoveryRecords: [initialA, initialB]
        )
        try fixture.operationRecoveryStore.upsert(operationRecord)
        appState.workspaceMutationOperationRecoveryRecords[operationRecord.id] =
            operationRecord
        appState.quarantineWorkspaceMutationSessions(
            recoveryID: operationRecord.id,
            sessions: [sessionA, sessionB]
        )
        appState.markWorkspaceMutationRecoveryBundledTextCommitted(
            id: operationRecord.id
        )
        fixture.operationRecoveryStore.removeError =
            TestWorkspaceMutationRecoveryStoreError.failed
        XCTAssertThrowsError(
            try appState.removePersistedWorkspaceMutationRecovery(
                id: operationRecord.id
            )
        )
        XCTAssertEqual(
            appState.workspaceMutationOperationRecoveryRecords[
                operationRecord.id
            ]?.textRecoveryRecords.count,
            2
        )
        fixture.recoveryStore.upsertError =
            TestWorkspaceMutationRecoveryStoreError.failed

        appState.applyDocumentText("A newest", to: sessionA)
        XCTAssertThrowsError(
            try appState.persistWorkspaceMutationTextRecovery(for: sessionA)
        )
        appState.workspaceMutationTextRecoveryTasks[
            ObjectIdentifier(sessionA)
        ]?.cancel()
        appState.workspaceMutationTextRecoveryTasks[ObjectIdentifier(sessionA)] = nil
        var persisted = try XCTUnwrap(
            fixture.operationRecoveryStore.records[operationRecord.id]
        )
        XCTAssertEqual(
            persisted.textRecoveryRecords.first { $0.id == initialA.id }?.source,
            "A newest"
        )
        XCTAssertEqual(
            persisted.textRecoveryRecords.first { $0.id == initialB.id },
            initialB
        )

        appState.applyDocumentText("B newest via debounce", to: sessionB)
        try await Task.sleep(nanoseconds: 350_000_000)

        persisted = try XCTUnwrap(
            fixture.operationRecoveryStore.records[operationRecord.id]
        )
        XCTAssertEqual(
            persisted.textRecoveryRecords.first { $0.id == initialA.id }?.source,
            "A newest"
        )
        XCTAssertEqual(
            persisted.textRecoveryRecords.first { $0.id == initialB.id }?.source,
            "B newest via debounce"
        )
        XCTAssertTrue(
            appState.workspaceMutationOperationRecoveryIDsWithUnpromotedText
                .contains(operationRecord.id)
        )
    }

    // swiftlint:disable:next function_body_length
    func testAuditBPromotionRetryUsesNewestPerIDAndClearsOnlyAfterAllSucceed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromotionRetryAudit")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryA = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let recoveryB = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let bundleA = WorkspaceMutationTextRecoveryRecord(
            id: recoveryA,
            originalURL: root.appendingPathComponent("a.md"),
            fileKind: .markdown,
            source: "A bundle old",
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            reason: .indeterminateMutation
        )
        let bundleB = WorkspaceMutationTextRecoveryRecord(
            id: recoveryB,
            originalURL: root.appendingPathComponent("b.md"),
            fileKind: .markdown,
            source: "B bundle",
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 1),
            reason: .indeterminateMutation
        )
        let pendingA = WorkspaceMutationTextRecoveryRecord(
            id: recoveryA,
            originalURL: bundleA.originalURL,
            fileKind: .markdown,
            source: "A pending newest",
            revision: 3,
            updatedAt: Date(timeIntervalSince1970: 3),
            reason: .indeterminateMutation
        )
        let pendingB = WorkspaceMutationTextRecoveryRecord(
            id: recoveryB,
            originalURL: bundleB.originalURL,
            fileKind: .markdown,
            source: "B pending old",
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 2),
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundleA, bundleB]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        try operationStore.upsert(operationRecord)
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceMutationOperationRecoveryRecords[operationRecord.id] =
            operationRecord
        appState.pendingWorkspaceMutationTextRecoveryRecords = [pendingA, pendingB]
        let liveB = DocumentSession(
            text: "B live revision four",
            url: bundleB.originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        appState.workspaceMutationTextRecoveryContexts[ObjectIdentifier(liveB)] =
            WorkspaceMutationTextRecoveryContext(
                recoveryID: recoveryB,
                originalURL: bundleB.originalURL,
                fileKind: .markdown,
                reason: .indeterminateMutation,
                persistedRevision: nil,
                sessionRevisionBaseline: liveB.version,
                logicalRevisionBaseline: 4
            )
        appState.workspaceMutationTextRecoverySessions[recoveryB] = liveB
        appState.workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
            operationRecord.id
        )
        textStore.upsertErrorsByID[recoveryB] =
            TestWorkspaceMutationRecoveryStoreError.failed

        XCTAssertThrowsError(
            try appState.removePersistedWorkspaceMutationRecovery(
                id: operationRecord.id
            )
        )

        XCTAssertEqual(textStore.records[recoveryA], pendingA)
        XCTAssertNil(textStore.records[recoveryB])
        XCTAssertTrue(
            appState.workspaceMutationOperationRecoveryIDsWithUnpromotedText
                .contains(operationRecord.id)
        )
        XCTAssertNotNil(operationStore.records[operationRecord.id])

        textStore.upsertErrorsByID[recoveryB] = nil
        appState.applyDocumentText("B live newest", to: liveB)
        try appState.removePersistedWorkspaceMutationRecovery(
            id: operationRecord.id
        )
        appState.workspaceMutationTextRecoveryTasks[
            ObjectIdentifier(liveB)
        ]?.cancel()

        XCTAssertEqual(textStore.records[recoveryA], pendingA)
        XCTAssertEqual(textStore.records[recoveryB]?.source, "B live newest")
        XCTAssertEqual(textStore.records[recoveryB]?.revision, 5)
        XCTAssertFalse(
            appState.workspaceMutationOperationRecoveryIDsWithUnpromotedText
                .contains(operationRecord.id)
        )
        XCTAssertNil(operationStore.records[operationRecord.id])
    }

    func testBundlePromotionFailureBlocksStopTracking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledTextPromotionFailure")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("post.md"),
            fileKind: .markdown,
            source: "Must remain bundled",
            revision: 1,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.upsertError = TestWorkspaceMutationRecoveryStoreError.failed
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()
        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertNotNil(operationStore.records[operationRecord.id])
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
        XCTAssertTrue(textStore.records.isEmpty)
    }

    func testOperationRemovalThatDeletesBeforeThrowRepairsJournalAndRestarts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationRemovalRepair")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try makeCreationOperationRecoveryRecord(rootURL: root)
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        operationStore.removeRecordBeforeThrow = true
        operationStore.removeError =
            TestWorkspaceMutationRecoveryStoreError.failed
        operationStore.failNextUpsertCount = 1

        XCTAssertThrowsError(
            try appState.releaseWorkspaceMutationRecovery(id: record.id)
        )

        XCTAssertEqual(
            operationStore.records[record.id],
            appState.workspaceMutationOperationRecoveryRecords[record.id]
        )
        XCTAssertEqual(operationStore.failNextUpsertCount, 0)
        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id])

        let relaunched = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        relaunched.restoreLastOpenedFileIfNeeded()

        XCTAssertNotNil(relaunched.workspaceMutationRecoveries[record.id])
        XCTAssertEqual(
            relaunched.workspaceMutationReconciliationPrompt?.recoveryID,
            record.id
        )
    }

    func testRootMismatchRemainsFencedAcrossCheckAgainAndRemovalFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MismatchedOperationRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let mismatchedRootExpectation = WorkspaceItemMutationExpectation(
            identity: WorkspaceFileSystemIdentity(
                device: authority.directoryMutationExpectation.identity.device,
                inode: authority.directoryMutationExpectation.identity.inode &+ 1
            ),
            kind: .directory
        )
        let record = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            rootExpectation: mismatchedRootExpectation
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [record]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        guard let initialRecovery = appState.workspaceMutationRecoveries[record.id],
              case .unavailable = initialRecovery
        else {
            return XCTFail("Root mismatch must remain globally tracked")
        }
        appState.reconcileCurrentWorkspaceMutationRecovery()
        guard let retriedRecovery = appState.workspaceMutationRecoveries[record.id],
              case .unavailable = retriedRecovery
        else {
            return XCTFail("Check Again must not adopt a replacement root")
        }

        operationStore.removeError = TestWorkspaceMutationRecoveryStoreError.failed
        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNotNil(operationStore.records[record.id])

        operationStore.removeError = nil
        appState.performWorkspaceMutationRecoverySecondaryAction()
        XCTAssertNil(appState.workspaceMutationRecoveries[record.id])
        XCTAssertNil(operationStore.records[record.id])
    }

    func testEscapedRelocationItemAuthorityRemainsRecoveryCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapedRelocationCandidate")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let escapedParent = root.deletingLastPathComponent()
            .appendingPathComponent(
                "escaped-relocation-candidate-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: escapedParent,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: escapedParent)
        }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let source = try authority.location(relativePath: "post.md")
        let destination = try authority.location(relativePath: "renamed.md")
        try "Moved".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: source)
        let parentExpectation = authority.directoryMutationExpectation
        let escapedURL = escapedParent.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: source.fileURL, to: escapedURL)
        let escapedLocation = try WorkspaceFileSystemLocation(fileURL: escapedURL)
        let recoveryID = UUID()
        let context = WorkspaceRelocationRecoveryContext(
            id: recoveryID,
            source: source,
            destination: destination,
            expectation: expectation,
            sourceParentExpectation: parentExpectation,
            destinationParentExpectation: parentExpectation,
            sourceParentBookmarkData: nil,
            sourceParentDisplayURL: nil,
            sourceLeafName: nil,
            sourceParentAuthorityExpectation: parentExpectation,
            sourceParentAuthorityLocation: nil,
            destinationParentBookmarkData: nil,
            destinationParentDisplayURL: nil,
            destinationLeafName: nil,
            destinationParentAuthorityExpectation: parentExpectation,
            destinationParentAuthorityLocation: nil,
            relocatedItemBookmarkData: Data("item-locator".utf8),
            relocatedItemDisplayURL: source.fileURL,
            relocatedItemAuthorityLocation: escapedLocation,
            sessionCommitState: .pending,
            reason: .namespaceChanged,
            actualMovedExpectation: expectation,
            records: [],
            remainingSessionIDs: []
        )
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceMutationRecoveries[recoveryID] = .relocation(context)

        XCTAssertTrue(appState.isWorkspaceMutationRecoveryCandidate(escapedLocation))
    }

    func testReportedTrashItemAuthorityRemainsRecoveryCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportedTrashCandidate")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trashParent = root.deletingLastPathComponent()
            .appendingPathComponent(
                "reported-trash-candidate-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: trashParent,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: trashParent)
        }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let source = try authority.location(relativePath: "post.md")
        try "Trashed".write(to: source.fileURL, atomically: false, encoding: .utf8)
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(at: source)
        let reportedTrashURL = trashParent.appendingPathComponent("post.md")
        try FileManager.default.moveItem(at: source.fileURL, to: reportedTrashURL)
        let reportedTrashLocation = try WorkspaceFileSystemLocation(
            fileURL: reportedTrashURL
        )
        let recoveryID = UUID()
        let context = WorkspaceTrashRecoveryContext(
            id: recoveryID,
            source: source,
            expectation: expectation,
            sourceParentExpectation: authority.directoryMutationExpectation,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: reportedTrashURL,
            reportedTrashBookmarkData: Data("trash-locator".utf8),
            reportedTrashAuthorityLocation: reportedTrashLocation,
            cleanupState: .removed,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceMutationRecoveries[recoveryID] = .trash(context)

        XCTAssertTrue(appState.isWorkspaceMutationRecoveryCandidate(reportedTrashLocation))
    }

    func testRestoredSaveCopyCannotOverwriteNestedOperationCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NestedOperationSaveCopyFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = nested.appendingPathComponent("target.md")
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("original.md"),
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            destinationRelativePath: "nested/target.md",
            textRecoveryRecords: [bundledText]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(
                records: [operationRecord]
            ),
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: destination)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoredSaveCopyCannotShadowRecoveryOwnedDescendantWithFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AncestorShadowSaveCopyFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("archive")
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("missing.md"),
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            destinationRelativePath: "archive/post.md",
            textRecoveryRecords: [bundledText]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(
                records: [operationRecord]
            ),
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: destination)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
    }

    func testRestoredSaveCopyRejectsCaseAliasOfMissingRecoveryCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaseAliasSaveCopyFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let recoveryCandidate = try authority.location(relativePath: "Post.md")
        guard try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(
            of: recoveryCandidate
        ) else {
            throw XCTSkip("Case-alias Save Copy requires a case-insensitive test volume")
        }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("missing.md"),
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            destinationRelativePath: "Post.md",
            textRecoveryRecords: [bundledText]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(
                records: [operationRecord]
            ),
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        let destination = root.appendingPathComponent("post.md")

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: destination)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
    }

    func testDetachedSaveCopyCannotShadowCachedAnchoredDescendantWithFile() throws {
        let fixture = try makeFixture(
            files: [
                "source.md": "Source",
                "archive/post.md": "Owned",
            ],
            currentPath: "source.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let source = appState.currentDocument
        let sourceURL = fixture.url("source.md")
        let owner = try fixture.installSession(
            path: "archive/post.md",
            storage: .cached
        )
        appState.applyDocumentText("Detached source", to: source)
        try FileManager.default.removeItem(at: sourceURL)
        appState.markSessionDetachedFromMissingFile(source, url: sourceURL)
        try FileManager.default.removeItem(at: fixture.url("archive"))
        let destination = fixture.url("archive")

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: destination)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: owner))
        XCTAssertEqual(source.text, "Detached source")
        XCTAssertTrue(source.isDirty)
    }

    func testPreparedCreationItemAuthorityRejectsSaveCopyAtThirdLocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCreationSaveCopyFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let thirdLocation = try authority.location(relativePath: "held-created.md")
        try "Prepared artifact".write(
            to: thirdLocation.fileURL,
            atomically: false,
            encoding: .utf8
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(
            at: thirdLocation
        )
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("missing.md"),
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        )
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationRecord = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "logical-created.md",
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: expectation,
                recoveryState: .retained(relativePath: stagingRelativePath),
                recoveryExpectation: expectation,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: thirdLocation.fileURL
            ),
            bookmarkAccess: bookmarkAccess,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: thirdLocation.fileURL)
        )

        XCTAssertEqual(
            try String(contentsOf: thirdLocation.fileURL, encoding: .utf8),
            "Prepared artifact"
        )
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
    }

    func testPreparedFolderCreationItemAuthorityRejectsSaveCopyDescendant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCreationSubtreeSaveCopyFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let thirdLocation = try authority.location(relativePath: "held-created-folder")
        try FileManager.default.createDirectory(
            at: thirdLocation.fileURL,
            withIntermediateDirectories: false
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspectExact(
            at: thirdLocation
        )
        let stagingRelativePath = ".plainsong-create-\(UUID().uuidString.lowercased())"
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("missing.md"),
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        )
        let bookmarkAccess = PassthroughWorkspaceMutationBookmarkAccess()
        let operationRecord = try makeLocatedCreationOperationRecoveryRecord(
            rootURL: root,
            specification: .init(
                destinationRelativePath: "logical-created-folder",
                publicationPhase: .prepared,
                kind: .folder,
                isPlanned: true,
                expectedCreatedItem: expectation,
                recoveryState: .retained(relativePath: stagingRelativePath),
                recoveryExpectation: expectation,
                publicationSourceRelativePath: stagingRelativePath,
                createdItemBookmarkURL: thirdLocation.fileURL
            ),
            bookmarkAccess: bookmarkAccess,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        let descendant = thirdLocation.fileURL.appendingPathComponent("copy.md")

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: descendant)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: descendant.path))
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
    }

    func testRecoveryStoreLoadFailureSurfacesAndSkipsLastOpened() {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let lastOpenedStore = RecordingLastOpenedFileStore(
            restoredURL: URL(fileURLWithPath: "/tmp/last-opened.md")
        )
        let appState = AppState(
            lastOpenedFileStore: lastOpenedStore,
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: true
        )

        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(lastOpenedStore.restoreCallCount, 0)
        XCTAssertEqual(
            appState.presentedError?.title,
            "Could Not Load Workspace Recovery"
        )
    }

    func testTextRecoveryStoreLoadFailureSurfacesAndSkipsLastOpened() {
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let lastOpenedStore = RecordingLastOpenedFileStore(
            restoredURL: URL(fileURLWithPath: "/tmp/last-opened.md")
        )
        let appState = AppState(
            lastOpenedFileStore: lastOpenedStore,
            workspaceMutationOperationRecoveryStore:
            RecordingWorkspaceMutationOperationRecoveryStore(),
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: true
        )

        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertEqual(lastOpenedStore.restoreCallCount, 0)
        XCTAssertEqual(
            appState.presentedError?.title,
            "Could Not Load Workspace Recovery"
        )
    }

    func testRecoveryLoadFailureFencesSaveAutosaveSaveCopyAndImageInsertion() throws {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let fixture = try makeFixture(
            files: ["post.md": "Original"],
            currentPath: "post.md",
            operationRecoveryStore: operationStore
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sourceURL = fixture.url("post.md")
        let saveCopyURL = fixture.url("copy.md")

        appState.applyDocumentText("Memory-only input", to: session)

        XCTAssertEqual(session.text, "Memory-only input")
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(appState.canSave)
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertNil(appState.autosaveTask)
        XCTAssertThrowsError(try appState.save(session: session))
        XCTAssertEqual(
            try String(contentsOf: sourceURL, encoding: .utf8),
            "Original"
        )

        appState.missingFilePrompt = .init(fileURL: sourceURL)
        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: saveCopyURL)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveCopyURL.path))
        XCTAssertNil(appState.editorImageAssetInserter)
    }

    func testRecoveryLoadFailureFencesOpenCloseNamespaceMutationAndTermination() throws {
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let fixture = try makeFixture(
            files: [
                "post.md": "Original",
                "other.md": "Other",
            ],
            currentPath: "post.md",
            recoveryStore: textStore
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let originalSession = appState.currentDocument
        let source = try fixture.location("post.md")
        let destination = fixture.url("renamed.md")

        XCTAssertThrowsError(
            try appState.open(
                url: fixture.url("other.md"),
                rememberAsLastOpened: false,
                preserveWorkspace: true
            )
        )
        XCTAssertTrue(appState.currentDocument === originalSession)
        XCTAssertThrowsError(try appState.closeWorkspaceForReplacement())
        XCTAssertTrue(appState.currentDocument === originalSession)

        XCTAssertThrowsError(
            try appState.renameWorkspaceItem(
                at: source,
                to: "renamed.md",
                expecting: fixture.expectation("post.md"),
                sourceParentExpectation: fixture.parentExpectation("post.md")
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(appState.prepareForTermination())

        appState.missingFilePrompt = .init(fileURL: source.fileURL)
        appState.closeMissingFile()
        XCTAssertTrue(appState.currentDocument === originalSession)
    }

    func testRecoveryLoadFailureBannerSurvivesDismissAndFailedStopTracking() {
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        operationStore.quarantineError = TestWorkspaceMutationRecoveryStoreError.failed
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore:
            RecordingWorkspaceMutationTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertTrue(appState.hasWorkspaceMutationRecoveryLoadFailure)
        appState.dismissError()
        XCTAssertTrue(appState.hasWorkspaceMutationRecoveryLoadFailure)

        appState.stopTrackingWorkspaceMutationRecoveryLoadFailure()

        XCTAssertEqual(operationStore.quarantineCallCount, 1)
        XCTAssertTrue(appState.workspaceMutationOperationRecoveryLoadFailed)
        XCTAssertTrue(appState.hasWorkspaceMutationRecoveryLoadFailure)
        XCTAssertFalse(appState.prepareForTermination())
    }

    func testSuccessfulTextStoreQuarantinePromotesBundleAndKeepsOperationRecoveryVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextLoadFailurePromotion")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("post.md"),
            fileKind: .markdown,
            source: "Recovered after quarantine",
            revision: 4,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        XCTAssertTrue(textStore.records.isEmpty)

        appState.stopTrackingWorkspaceMutationRecoveryLoadFailure()

        XCTAssertFalse(appState.hasWorkspaceMutationRecoveryLoadFailure)
        XCTAssertEqual(textStore.quarantineCallCount, 1)
        XCTAssertEqual(textStore.records[bundledText.id], bundledText)
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.operation,
            .creation
        )
        XCTAssertEqual(
            appState.workspaceMutationTextRecoverySessions[bundledText.id]?.text,
            bundledText.source
        )

        textStore.upsertError = TestWorkspaceMutationRecoveryStoreError.failed
        appState.applyDocumentText(
            "New input after quarantine",
            to: appState.currentDocument
        )
        XCTAssertThrowsError(
            try appState.persistWorkspaceMutationTextRecovery(
                for: appState.currentDocument
            )
        )
        let updatedOperation = try XCTUnwrap(
            operationStore.records[operationRecord.id]
        )
        XCTAssertEqual(
            updatedOperation.textRecoveryRecords.first {
                $0.id == bundledText.id
            }?.source,
            "New input after quarantine"
        )
    }

    func testSuccessfulOperationStoreQuarantineLeavesLoadedTextRecoveryActionable() {
        let textRecord = WorkspaceMutationTextRecoveryRecord(
            originalURL: URL(fileURLWithPath: "/tmp/recovered.md"),
            fileKind: .markdown,
            source: "Standalone recovery",
            revision: 2,
            reason: .indeterminateMutation
        )
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore()
        operationStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let textStore = RecordingWorkspaceMutationTextRecoveryStore(
            records: [textRecord]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        XCTAssertEqual(appState.currentDocument.text, textRecord.source)

        appState.stopTrackingWorkspaceMutationRecoveryLoadFailure()

        XCTAssertFalse(appState.hasWorkspaceMutationRecoveryLoadFailure)
        XCTAssertEqual(operationStore.quarantineCallCount, 1)
        XCTAssertEqual(appState.currentDocument.text, textRecord.source)
        XCTAssertNotNil(
            appState.workspaceMutationTextRecoveryContexts[
                ObjectIdentifier(appState.currentDocument)
            ]
        )
    }

    func testTextLoadFailureDoesNotOverwriteUnknownStandaloneWithOlderBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextLoadFailureBundleFence")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundledText = WorkspaceMutationTextRecoveryRecord(
            originalURL: root.appendingPathComponent("post.md"),
            fileKind: .markdown,
            source: "Potentially stale bundle",
            revision: 1,
            reason: .indeterminateMutation
        )
        let operationRecord = try makeCreationOperationRecoveryRecord(
            rootURL: root,
            textRecoveryRecords: [bundledText]
        )
        let textStore = RecordingWorkspaceMutationTextRecoveryStore()
        textStore.loadError = TestWorkspaceMutationRecoveryStoreError.failed
        let operationStore = RecordingWorkspaceMutationOperationRecoveryStore(
            records: [operationRecord]
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )

        appState.restoreLastOpenedFileIfNeeded()

        XCTAssertTrue(textStore.records.isEmpty)
        XCTAssertNotNil(operationStore.records[operationRecord.id])
        XCTAssertNotNil(appState.workspaceMutationRecoveries[operationRecord.id])
        XCTAssertEqual(
            appState.presentedError?.title,
            "Could Not Load Workspace Recovery"
        )
    }

    private struct PersistedReportedTrashFixture {
        let rootURL: URL
        let reportedTrashURL: URL
        let sourceParentBookmarkData: Data
        let record: WorkspaceMutationOperationRecoveryRecord

        func cleanUp() {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: reportedTrashURL)
        }
    }

    private func makePersistedReportedTrashFixture(
        bookmarkData: Data?
    ) throws -> PersistedReportedTrashFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistedReportedTrashRecovery")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let source = try authority.location(relativePath: "post.md")
        try "Original".write(
            to: source.fileURL,
            atomically: false,
            encoding: .utf8
        )
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: source)
        let sourceParentExpectation =
            try WorkspaceNoFollowItemInspector.inspectParent(of: source)
        let rootBookmarkData = try SecurityScopedAccess.withAccess(to: rootURL) {
            try rootURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        let sourceParentBookmarkData = Data(
            "source-parent-\(UUID().uuidString)".utf8
        )
        let reportedTrashURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("reported-trash-\(UUID().uuidString).md")
        try FileManager.default.moveItem(
            at: source.fileURL,
            to: reportedTrashURL
        )
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 3),
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: authority.canonicalRootURL,
            rootExpectation: .init(authority.directoryMutationExpectation),
            payload: .trash(.init(
                sourceRelativePath: source.relativePath,
                expectation: .init(expectation),
                sourceParentExpectation: .init(sourceParentExpectation),
                sourceParentBookmarkData: sourceParentBookmarkData,
                sourceParentDisplayURL: rootURL,
                sourceLeafName: source.fileURL.lastPathComponent,
                sourceParentAuthorityExpectation: .init(sourceParentExpectation),
                expectedItemBookmarkData: bookmarkData,
                expectedItemDisplayURL: reportedTrashURL,
                sessionCommitPhase: .committedCleanup,
                reason: .sourceChanged,
                recoveryRelativePath: nil,
                reportedTrashURL: reportedTrashURL,
                reportedTrashBookmarkData: bookmarkData,
                cleanupState: .removed,
                actualStagedExpectation: nil,
                actualStagedEntryRecoveryRelativePath: nil
            )),
            textRecoveryRecords: []
        )
        return PersistedReportedTrashFixture(
            rootURL: rootURL,
            reportedTrashURL: reportedTrashURL,
            sourceParentBookmarkData: sourceParentBookmarkData,
            record: record
        )
    }

    private struct LocatedCreationRecoveryRecordSpecification {
        let destinationRelativePath: String
        let publicationPhase:
            WorkspaceMutationOperationRecoveryRecord.CreationPublicationPhase
        var kind: WorkspaceMutationOperationRecoveryRecord.CreationKind = .file
        var isPlanned = false
        var expectedCreatedItem: WorkspaceItemMutationExpectation?
        var recoveryState:
            WorkspaceMutationOperationRecoveryRecord.CreationRecoveryState = .none
        var recoveryExpectation: WorkspaceItemMutationExpectation?
        var publicationSourceRelativePath: String?
        var actualPublishedExpectation: WorkspaceItemMutationExpectation?
        var destinationParentURL: URL?
        var destinationParentExpectation: WorkspaceItemMutationExpectation?
        var createdItemBookmarkURL: URL?
        var createdItemDisplayURL: URL?
    }

    private func makeLocatedCreationOperationRecoveryRecord(
        rootURL: URL,
        specification: LocatedCreationRecoveryRecordSpecification,
        bookmarkAccess: PassthroughWorkspaceMutationBookmarkAccess,
        textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord] = []
    ) throws -> WorkspaceMutationOperationRecoveryRecord {
        let destinationURL = rootURL.appendingPathComponent(
            specification.destinationRelativePath
        )
        let destinationParentURL = specification.destinationParentURL ??
            destinationURL.deletingLastPathComponent()
        let parentLocation = try WorkspaceFileSystemLocation(
            fileURL: destinationParentURL
        )
        let parentExpectation = try specification.destinationParentExpectation ??
            WorkspaceNoFollowItemInspector.inspectExact(at: parentLocation)
        let destinationParentBookmarkData = try bookmarkAccess.makeBookmark(
            for: destinationParentURL
        )
        let createdItemBookmarkData = try specification.createdItemBookmarkURL.map {
            try bookmarkAccess.makeBookmark(for: $0)
        }
        let creation = WorkspaceMutationOperationRecoveryRecord.Creation(
            destinationRelativePath: specification.destinationRelativePath,
            kind: specification.kind,
            parentExpectation: .init(parentExpectation),
            destinationParentBookmarkData: destinationParentBookmarkData,
            destinationParentDisplayURL: destinationParentURL,
            destinationLeafName: destinationURL.lastPathComponent,
            destinationParentAuthorityExpectation: .init(parentExpectation),
            publicationPhase: specification.publicationPhase,
            isPlanned: specification.isPlanned,
            expectedCreatedItem: specification.expectedCreatedItem.map(
                WorkspaceMutationOperationRecoveryRecord.Expectation.init
            ),
            createdItemBookmarkData: createdItemBookmarkData,
            createdItemDisplayURL: specification.createdItemDisplayURL ??
                specification.createdItemBookmarkURL,
            reason: .namespaceChanged,
            recoveryState: specification.recoveryState,
            recoveryExpectation: specification.recoveryExpectation.map(
                WorkspaceMutationOperationRecoveryRecord.Expectation.init
            ),
            publicationSourceRelativePath:
            specification.publicationSourceRelativePath,
            actualPublishedExpectation:
            specification.actualPublishedExpectation.map(
                WorkspaceMutationOperationRecoveryRecord.Expectation.init
            )
        )
        return try makeCreationOperationRecoveryRecord(
            rootURL: rootURL,
            creation: creation,
            textRecoveryRecords: textRecoveryRecords
        )
    }

    private func makeCreationOperationRecoveryRecord(
        rootURL: URL,
        creation: WorkspaceMutationOperationRecoveryRecord.Creation,
        textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord] = []
    ) throws -> WorkspaceMutationOperationRecoveryRecord {
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let bookmarkData = try SecurityScopedAccess.withAccess(to: rootURL) {
            try rootURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        return WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 3),
            rootBookmarkData: bookmarkData,
            rootDisplayURL: authority.canonicalRootURL,
            rootExpectation: .init(authority.directoryMutationExpectation),
            payload: .creation(creation),
            textRecoveryRecords: textRecoveryRecords
        )
    }

    private func makeCreationOperationRecoveryRecord(
        rootURL: URL,
        destinationRelativePath: String = "post.md",
        kind: WorkspaceMutationOperationRecoveryRecord.CreationKind = .file,
        isPlanned: Bool? = nil,
        expectedCreatedItem: WorkspaceItemMutationExpectation? = nil,
        recoveryState: WorkspaceMutationOperationRecoveryRecord.CreationRecoveryState =
            .unknown,
        publicationSourceRelativePath: String? = nil,
        parentExpectation: WorkspaceItemMutationExpectation? = nil,
        rootExpectation: WorkspaceItemMutationExpectation? = nil,
        textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord] = []
    ) throws -> WorkspaceMutationOperationRecoveryRecord {
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let bookmarkData = try SecurityScopedAccess.withAccess(to: rootURL) {
            try rootURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        return WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 3),
            rootBookmarkData: bookmarkData,
            rootDisplayURL: authority.canonicalRootURL,
            rootExpectation: .init(
                rootExpectation ?? authority.directoryMutationExpectation
            ),
            payload: .creation(.init(
                destinationRelativePath: destinationRelativePath,
                kind: kind,
                parentExpectation: (
                    parentExpectation
                        ?? (isPlanned == true
                            ? authority.directoryMutationExpectation
                            : nil)
                ).map(WorkspaceMutationOperationRecoveryRecord.Expectation.init),
                isPlanned: isPlanned,
                expectedCreatedItem: expectedCreatedItem.map(
                    WorkspaceMutationOperationRecoveryRecord.Expectation.init
                ),
                reason: .namespaceChanged,
                recoveryState: recoveryState,
                recoveryExpectation: nil,
                publicationSourceRelativePath: publicationSourceRelativePath,
                actualPublishedExpectation: nil
            )),
            textRecoveryRecords: textRecoveryRecords
        )
    }

    private enum SessionStorage {
        case cached
        case retired
    }

    private func installWorkspaceDestinationOwner(
        _ ownerKind: WorkspaceDestinationOwnerKind,
        relativePath: String,
        fixture: Fixture
    ) throws {
        let appState = fixture.appState
        let ownedLocation = try fixture.location(relativePath)
        switch ownerKind {
        case .cached:
            _ = try fixture.installSession(path: relativePath, storage: .cached)
        case .retired:
            _ = try fixture.installSession(path: relativePath, storage: .retired)
        case .detached:
            _ = try fixture.installSession(path: relativePath, storage: .cached)
            appState.detachedSessionURLs.insert(ownedLocation.fileURL)
        case .recovery:
            let recoverySession = DocumentSession(
                text: "Owned",
                url: ownedLocation.fileURL,
                fileKind: .markdown
            )
            appState.workspaceMutationTextRecoverySessions[UUID()] = recoverySession
        case .pendingTextRecovery:
            appState.pendingWorkspaceMutationTextRecoveryRecords = [
                WorkspaceMutationTextRecoveryRecord(
                    originalURL: fixture.url("earlier-recovery.md"),
                    fileKind: .markdown,
                    source: "Earlier recovery",
                    revision: 1,
                    reason: .indeterminateMutation
                ),
                WorkspaceMutationTextRecoveryRecord(
                    originalURL: ownedLocation.fileURL,
                    fileKind: .markdown,
                    source: "Owned recovery",
                    revision: 1,
                    reason: .indeterminateMutation
                ),
            ]
            appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
            XCTAssertEqual(appState.pendingWorkspaceMutationTextRecoveryRecords.count, 1)
        case .pendingOperationRecovery:
            appState.pendingWorkspaceMutationOperationRecoveryRecords = try [
                makeCreationOperationRecoveryRecord(
                    rootURL: fixture.rootURL,
                    destinationRelativePath: relativePath
                ),
            ]
        }
    }

    private enum WorkspaceDestinationOwnerKind: CaseIterable, CustomStringConvertible {
        case cached
        case retired
        case detached
        case recovery
        case pendingTextRecovery
        case pendingOperationRecovery

        var description: String {
            switch self {
            case .cached: "cached"
            case .retired: "retired"
            case .detached: "detached"
            case .recovery: "recovery"
            case .pendingTextRecovery: "pending text recovery"
            case .pendingOperationRecovery: "pending operation recovery"
            }
        }
    }

    @MainActor
    private struct Fixture {
        let appState: AppState
        let rootURL: URL
        let rootAuthority: WorkspaceFileSystemRootAuthority
        let operationRecoveryStore: RecordingWorkspaceMutationOperationRecoveryStore
        let recoveryStore: RecordingWorkspaceMutationTextRecoveryStore

        func url(_ relativePath: String) -> URL {
            rootURL.appendingPathComponent(relativePath, isDirectory: false)
        }

        func location(_ relativePath: String) throws -> WorkspaceFileSystemLocation {
            try rootAuthority.location(relativePath: relativePath)
        }

        func expectation(_ relativePath: String) throws -> WorkspaceItemMutationExpectation {
            try WorkspaceNoFollowItemInspector.inspect(at: location(relativePath))
        }

        func parentExpectation(_ relativePath: String) throws -> WorkspaceItemMutationExpectation {
            try WorkspaceNoFollowItemInspector.inspectParent(of: location(relativePath))
        }

        func installSession(
            path: String,
            storage: SessionStorage
        ) throws -> DocumentSession {
            let location = try location(path)
            let loaded = try MarkdownFileStore().loadResult(at: location)
            let session = DocumentSession(
                text: loaded.file.text,
                url: location.fileURL,
                fileKind: loaded.file.fileKind
            )
            let preparedAuthority = try prepareEditorImageAssetDocumentAuthority(
                at: location,
                expecting: loaded.metadata.identity
            )
            appState.adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: location,
                    identity: loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest
                ),
                for: session,
                preparedImageAssetAuthority: preparedAuthority,
                allowsImageAssetAuthorityBootstrap: true
            )
            appState.recordKnownSessionDiskText(
                loaded.file.text,
                for: session,
                canonicalURL: location.fileURL
            )
            _ = appState.sessionPolicy.access(location.fileURL, isDirty: false)
            switch storage {
            case .cached:
                appState.sessionCache[location.fileURL] = session
            case .retired:
                appState.retiredEditorDocumentSessions[location.fileURL] =
                    RetiredEditorDocumentSession(
                        canonicalURL: location.fileURL,
                        session: session,
                        bindingIDs: [],
                        awaitingInstallations: [],
                        securityScopedAuthorityOwners: []
                    )
            }
            return session
        }
    }

    private func makeFixture(
        files: [String: String],
        directories: [String] = [],
        currentPath: String,
        recycler: (any WorkspaceItemRecycling)? = nil,
        operationRecoveryStore: RecordingWorkspaceMutationOperationRecoveryStore =
            RecordingWorkspaceMutationOperationRecoveryStore(),
        recoveryStore: RecordingWorkspaceMutationTextRecoveryStore =
            RecordingWorkspaceMutationTextRecoveryStore(),
        reportedTrashBookmarkAccess:
        any ReportedTrashBookmarkAccessing =
            PassthroughWorkspaceMutationBookmarkAccess()
    ) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateWorkspaceDataIntegrityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        for directory in directories {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for (path, text) in files {
            let fileURL = rootURL.appendingPathComponent(path, isDirectory: false)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let currentLocation = try rootAuthority.location(relativePath: currentPath)
        let currentRead = try MarkdownFileStore().loadResult(at: currentLocation)
        let current = DocumentSession(
            text: currentRead.file.text,
            url: currentLocation.fileURL,
            fileKind: currentRead.file.fileKind
        )
        let entries = try directories.map { path in
            let location = try rootAuthority.location(relativePath: path)
            return try WorkspaceFileSnapshot.Entry(
                relativePath: path,
                kind: .directory,
                identity: "directory:\(path)",
                contentModificationDate: nil,
                mutationExpectation: WorkspaceNoFollowItemInspector.inspect(at: location)
            )
        } + files.keys.map { path in
            let location = try rootAuthority.location(relativePath: path)
            return try WorkspaceFileSnapshot.Entry(
                relativePath: path,
                kind: WorkspaceFileKind(url: rootURL.appendingPathComponent(path), isDirectory: false),
                identity: "file:\(path)",
                contentModificationDate: nil,
                mutationExpectation: WorkspaceNoFollowItemInspector.inspect(at: location)
            )
        }
        let snapshot = WorkspaceFileSnapshot(entries: entries)
        let bookmarkAccess = reportedTrashBookmarkAccess as?
            PassthroughWorkspaceMutationBookmarkAccess
        operationRecoveryStore.automaticallyTrackedBookmarkAccess = bookmarkAccess
        let trackedRecycler = recycler.map { recycler in
            if let bookmarkAccess {
                BookmarkTrackingMutationRecycler(
                    base: recycler,
                    bookmarkAccess: bookmarkAccess
                ) as any WorkspaceItemRecycling
            } else {
                recycler
            }
        }
        let fileOperations = trackedRecycler.map(WorkspaceFileOperations.init(recycler:))
            ?? WorkspaceFileOperations()
        let appState = AppState(
            currentDocument: current,
            directoryScanner: MutationImmediateDirectoryScanner(snapshot: snapshot),
            fileOperations: fileOperations,
            workspaceMutationOperationRecoveryStore: operationRecoveryStore,
            workspaceMutationTextRecoveryStore: recoveryStore,
            reportedTrashBookmarkAccess: reportedTrashBookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = snapshot
        appState.workspaceSearchRootAuthority = rootAuthority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: snapshot,
            options: .init(showAllFiles: true)
        )
        let preparedAuthority = try prepareEditorImageAssetDocumentAuthority(
            at: currentLocation,
            expecting: currentRead.metadata.identity
        )
        appState.adoptAnchoredFileBinding(
            AnchoredWorkspaceSessionFileBinding(
                location: currentLocation,
                identity: currentRead.metadata.identity,
                sha256Digest: currentRead.sha256Digest
            ),
            for: current,
            preparedImageAssetAuthority: preparedAuthority,
            allowsImageAssetAuthorityBootstrap: true
        )
        appState.sessionCache[currentLocation.fileURL] = current
        appState.recordKnownSessionDiskText(
            currentRead.file.text,
            for: current,
            canonicalURL: currentLocation.fileURL
        )
        _ = appState.sessionPolicy.access(currentLocation.fileURL, isDirty: false)
        return Fixture(
            appState: appState,
            rootURL: rootURL,
            rootAuthority: rootAuthority,
            operationRecoveryStore: operationRecoveryStore,
            recoveryStore: recoveryStore
        )
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.appState.autosaveTask?.cancel()
        fixture.appState.statisticsTask?.cancel()
        fixture.appState.workspaceReloadTask?.cancel()
        fixture.appState.completionWorkspaceTask?.cancel()
        for task in fixture.appState.sessionAutosaveTasks.values {
            task.task.cancel()
        }
        for task in fixture.appState.sessionStatisticsTasks.values {
            task.task.cancel()
        }
        for task in fixture.appState.externalDiskInspectionTasks.values {
            task.task.cancel()
        }
        for task in fixture.appState.externalReloadTasks.values {
            task.task.cancel()
        }
        fixture.appState.workspaceWatcher?.stop()
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }
}

// swiftlint:enable type_body_length

private struct MutationImmediateDirectoryScanner: WorkspaceDirectoryScanning {
    let snapshot: WorkspaceFileSnapshot

    func snapshot(root _: URL) async throws -> WorkspaceFileSnapshot {
        snapshot
    }

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        try WorkspaceDirectorySnapshotCapture(
            snapshot: snapshot,
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root)
        )
    }
}

private actor RecordingMutationRecycler: WorkspaceItemRecycling {
    private var urls: [URL] = []

    func recycle(_ requests: [WorkspaceItemRecycleRequest]) async throws -> [UUID: URL] {
        urls.append(contentsOf: requests.map(\.lexicalURL))
        return [:]
    }

    func recordedURLs() -> [URL] {
        urls
    }
}

private final class BookmarkTrackingMutationRecycler:
    WorkspaceItemRecycling,
    @unchecked Sendable
{
    private let base: any WorkspaceItemRecycling
    private let bookmarkAccess: PassthroughWorkspaceMutationBookmarkAccess

    init(
        base: any WorkspaceItemRecycling,
        bookmarkAccess: PassthroughWorkspaceMutationBookmarkAccess
    ) {
        self.base = base
        self.bookmarkAccess = bookmarkAccess
    }

    func recycle(
        _ requests: [WorkspaceItemRecycleRequest]
    ) async throws -> [UUID: URL] {
        let results = try await base.recycle(requests)
        for reportedURL in results.values {
            bookmarkAccess.redirectExistingBookmarks(matchingItemAt: reportedURL)
        }
        return results
    }
}

private actor RemovingMutationRecycler: WorkspaceItemRecycling {
    func recycle(_ requests: [WorkspaceItemRecycleRequest]) async throws -> [UUID: URL] {
        var mapping: [UUID: URL] = [:]
        for request in requests {
            let url = try request.resolvedFileURL()
            let trashURL = testTrashURL(for: url)
            try FileManager.default.moveItem(at: url, to: trashURL)
            mapping[request.id] = trashURL
        }
        return mapping
    }
}

private actor ControlledRemovingMutationRecycler: WorkspaceItemRecycling {
    private var continuation: CheckedContinuation<[UUID: URL], Error>?
    private var requests: [WorkspaceItemRecycleRequest] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var movedRequestMapping: [UUID: URL]?

    func recycle(
        _ requests: [WorkspaceItemRecycleRequest]
    ) async throws -> [UUID: URL] {
        self.requests = requests
        let waiters = callWaiters
        callWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCalled() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func complete() {
        do {
            _ = try moveRequestsWithoutCompleting()
            completeMovedRequests()
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func moveRequestsWithoutCompleting() throws -> [URL] {
        if let movedRequestMapping {
            return Array(movedRequestMapping.values)
        }
        var mapping: [UUID: URL] = [:]
        for request in requests {
            let url = try request.resolvedFileURL()
            let trashURL = testTrashURL(for: url)
            try FileManager.default.moveItem(at: url, to: trashURL)
            mapping[request.id] = trashURL
        }
        movedRequestMapping = mapping
        return Array(mapping.values)
    }

    func completeMovedRequests() {
        guard let movedRequestMapping else { return }
        continuation?.resume(returning: movedRequestMapping)
        continuation = nil
        self.movedRequestMapping = nil
    }
}

private actor ControlledFailingMutationRecycler: WorkspaceItemRecycling {
    private var continuation: CheckedContinuation<[UUID: URL], Error>?
    private var wasCalled = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func recycle(_: [WorkspaceItemRecycleRequest]) async throws -> [UUID: URL] {
        wasCalled = true
        let waiters = callWaiters
        callWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCalled() async {
        if wasCalled { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func fail() {
        continuation?.resume(throwing: ControlledMutationRecyclerError.failed)
        continuation = nil
    }
}

private enum ControlledMutationRecyclerError: Error {
    case failed
}

private enum TestWorkspaceMutationRecoveryStoreError: Error {
    case failed
}

private final class PassthroughWorkspaceMutationBookmarkAccess:
    WorkspaceMutationBookmarkAccessing
{
    var makeError: Error?
    var resolveError: Error?
    var unresolvableBookmarkData = Set<Data>()
    var resolutionURLReplacements: [URL: URL] = [:]
    var onResolve: ((Int, Data) throws -> Void)?
    private(set) var makeCallCount = 0
    private(set) var resolveCallCount = 0
    private var resolvedURLs: [Data: URL] = [:]
    private var expectedItemsByBookmark: [Data: WorkspaceItemMutationExpectation] = [:]
    private var resolutionOverridesByBookmark: [Data: URL] = [:]

    func redirectExistingBookmarks(createdFor originalURL: URL, to replacementURL: URL) {
        for (bookmarkData, recordedURL) in resolvedURLs
            where recordedURL.standardizedFileURL.path == originalURL.standardizedFileURL.path
        {
            resolutionOverridesByBookmark[bookmarkData] = replacementURL
        }
    }

    func redirectExistingBookmarksIfUnconfigured(
        createdFor originalURL: URL,
        to replacementURL: URL
    ) {
        for (bookmarkData, recordedURL) in resolvedURLs
            where recordedURL.standardizedFileURL.path == originalURL.standardizedFileURL.path
        {
            guard resolutionOverridesByBookmark[bookmarkData] == nil,
                  !resolutionURLReplacements.keys.contains(where: {
                      $0.standardizedFileURL.path == recordedURL.standardizedFileURL.path
                  })
            else {
                continue
            }
            resolutionOverridesByBookmark[bookmarkData] = replacementURL
        }
    }

    func redirectExistingBookmarks(matchingItemAt replacementURL: URL) {
        guard let replacementLocation = try? WorkspaceFileSystemLocation(
            fileURL: replacementURL
        ),
            let replacementExpectation = try? WorkspaceNoFollowItemInspector.inspectExact(
                at: replacementLocation
            )
        else {
            return
        }
        for (bookmarkData, expectation) in expectedItemsByBookmark
            where expectation == replacementExpectation
        {
            guard resolutionOverridesByBookmark[bookmarkData] == nil,
                  let recordedURL = resolvedURLs[bookmarkData],
                  !resolutionURLReplacements.keys.contains(where: {
                      $0.standardizedFileURL.path == recordedURL.standardizedFileURL.path
                  })
            else {
                continue
            }
            resolutionOverridesByBookmark[bookmarkData] = replacementURL
        }
    }

    func makeBookmark(for fileURL: URL) throws -> Data {
        makeCallCount += 1
        if let makeError { throw makeError }
        let bookmarkData = Data("bookmark-\(makeCallCount)".utf8)
        resolvedURLs[bookmarkData] = fileURL
        if let location = try? WorkspaceFileSystemLocation(fileURL: fileURL),
           let expectation = try? WorkspaceNoFollowItemInspector.inspectExact(
               at: location
           )
        {
            expectedItemsByBookmark[bookmarkData] = expectation
        }
        return bookmarkData
    }

    func resolveBookmark(
        _ bookmarkData: Data
    ) throws -> WorkspaceMutationBookmarkResolution {
        resolveCallCount += 1
        try onResolve?(resolveCallCount, bookmarkData)
        if let resolveError { throw resolveError }
        if unresolvableBookmarkData.contains(bookmarkData) {
            throw TestWorkspaceMutationRecoveryStoreError.failed
        }
        let recordedURL = resolvedURLs[bookmarkData]
        let replacementURL = recordedURL.flatMap { recordedURL in
            resolutionURLReplacements.first(where: {
                $0.key.standardizedFileURL.path == recordedURL.standardizedFileURL.path
            })?.value
        }
        guard let fileURL = resolutionOverridesByBookmark[bookmarkData] ??
            replacementURL ??
            recordedURL
        else {
            throw TestWorkspaceMutationRecoveryStoreError.failed
        }
        return WorkspaceMutationBookmarkResolution(fileURL: fileURL, isStale: false)
    }
}

private final class RecordingReportedTrashBookmarkAccess:
    ReportedTrashBookmarkAccessing
{
    var bookmarkData = Data("bookmark".utf8)
    var resolution: ReportedTrashBookmarkResolution?
    var resolutionsByBookmark: [Data: ReportedTrashBookmarkResolution] = [:]
    var makeError: Error?
    var resolveError: Error?
    private(set) var makeCallCount = 0
    private(set) var resolveCallCount = 0

    func makeBookmark(for _: URL) throws -> Data {
        makeCallCount += 1
        if let makeError { throw makeError }
        return bookmarkData
    }

    func resolveBookmark(
        _ bookmarkData: Data
    ) throws -> ReportedTrashBookmarkResolution {
        resolveCallCount += 1
        if let resolution = resolutionsByBookmark[bookmarkData] {
            return resolution
        }
        if let resolveError { throw resolveError }
        guard let resolution else {
            throw TestWorkspaceMutationRecoveryStoreError.failed
        }
        return resolution
    }
}

private final class RecordingLastOpenedFileStore: LastOpenedFilePersisting {
    let restoredURL: URL?
    private(set) var restoreCallCount = 0

    init(restoredURL: URL?) {
        self.restoredURL = restoredURL
    }

    func save(_: URL) throws {}

    func restore() throws -> URL? {
        restoreCallCount += 1
        return restoredURL
    }
}

private final class RecordingWorkspaceMutationOperationRecoveryStore:
    WorkspaceMutationOperationRecoveryPersisting
{
    var records: [UUID: WorkspaceMutationOperationRecoveryRecord]
    var loadError: Error?
    var upsertError: Error?
    var failNextUpsertCount = 0
    var removeError: Error?
    var removeRecordBeforeThrow = false
    var quarantineError: Error?
    private(set) var quarantineCallCount = 0
    var onUpsert: ((WorkspaceMutationOperationRecoveryRecord) -> Void)?
    var automaticallyTrackedBookmarkAccess:
        PassthroughWorkspaceMutationBookmarkAccess?

    init(records: [WorkspaceMutationOperationRecoveryRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        if let loadError { throw loadError }
        return records.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws {
        if failNextUpsertCount > 0 {
            failNextUpsertCount -= 1
            throw TestWorkspaceMutationRecoveryStoreError.failed
        }
        if let upsertError { throw upsertError }
        if case let .relocation(relocation) = record.payload {
            let sourceURL = record.rootDisplayURL.appendingPathComponent(
                relocation.sourceRelativePath
            )
            let destinationURL = record.rootDisplayURL.appendingPathComponent(
                relocation.destinationRelativePath
            )
            automaticallyTrackedBookmarkAccess?.redirectExistingBookmarks(
                matchingItemAt: destinationURL
            )
            if relocation.sessionCommitPhase == .committedCleanup,
               let destinationLocation = try? WorkspaceFileSystemLocation(
                   fileURL: destinationURL
               ),
               (try? WorkspaceNoFollowItemInspector.inspect(at: destinationLocation)) ==
               relocation.expectation.runtimeValue
            {
                automaticallyTrackedBookmarkAccess?
                    .redirectExistingBookmarksIfUnconfigured(
                        createdFor: sourceURL,
                        to: destinationURL
                    )
            }
        }
        onUpsert?(record)
        records[record.id] = record
    }

    func remove(id: UUID) throws {
        if removeRecordBeforeThrow {
            records[id] = nil
        }
        if let removeError { throw removeError }
        records[id] = nil
    }

    func quarantineAfterLoadFailure() throws {
        quarantineCallCount += 1
        if let quarantineError { throw quarantineError }
        loadError = nil
        records.removeAll()
    }
}

private final class RecordingWorkspaceMutationTextRecoveryStore:
    WorkspaceMutationTextRecoveryPersisting
{
    var records: [UUID: WorkspaceMutationTextRecoveryRecord]
    private(set) var quarantinedRecords: [UUID: WorkspaceMutationTextRecoveryRecord] = [:]
    var loadError: Error?
    var upsertError: Error?
    var upsertErrorsByID: [UUID: Error] = [:]
    var removeError: Error?
    var removeRecordBeforeThrow = false
    var recordQuarantineError: Error?
    var quarantineError: Error?
    private(set) var removeCallCount = 0
    private(set) var recordQuarantineCallCount = 0
    private(set) var quarantineCallCount = 0

    init(records: [WorkspaceMutationTextRecoveryRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func load() throws -> [WorkspaceMutationTextRecoveryRecord] {
        if let loadError { throw loadError }
        return records.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) throws {
        if let upsertError = upsertErrorsByID[record.id] {
            throw upsertError
        }
        if let upsertError { throw upsertError }
        records[record.id] = record
    }

    func remove(id: UUID) throws {
        removeCallCount += 1
        if removeRecordBeforeThrow {
            records[id] = nil
        }
        if let removeError { throw removeError }
        records[id] = nil
    }

    func quarantine(id: UUID) throws {
        recordQuarantineCallCount += 1
        if let recordQuarantineError { throw recordQuarantineError }
        quarantinedRecords[id] = records.removeValue(forKey: id)
    }

    func quarantineAfterLoadFailure() throws {
        quarantineCallCount += 1
        if let quarantineError { throw quarantineError }
        loadError = nil
        records.removeAll()
    }
}

private func testTrashURL(for stagedURL: URL) -> URL {
    stagedURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".test-trash-\(UUID().uuidString)", isDirectory: false)
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
