// swiftlint:disable file_length type_body_length
import Darwin
import Foundation
@testable import Plainsong
import WorkspaceKit
import XCTest

final class WorkspaceMutationOperationRecoveryStoreTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testRoundTripsFullOperationBundleAcrossStoreInstances() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let creation = fixture.record(
            updatedAt: Date(timeIntervalSince1970: 1),
            payload: .creation(.init(
                destinationRelativePath: "草稿/Cafe\u{0301}.md",
                kind: .file,
                parentExpectation: fixture.expectation(
                    inode: 10,
                    kind: .directory
                ),
                destinationParentBookmarkData:
                Data("creation-parent-bookmark".utf8),
                destinationParentDisplayURL:
                URL(fileURLWithPath: "/tmp/moved-drafts"),
                destinationLeafName: "Cafe\u{0301}.md",
                destinationParentAuthorityExpectation: fixture.expectation(
                    inode: 10,
                    kind: .directory
                ),
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: fixture.expectation(
                    inode: 11,
                    kind: .regularFile
                ),
                createdItemBookmarkData:
                Data("creation-item-bookmark".utf8),
                createdItemDisplayURL:
                URL(fileURLWithPath: "/tmp/moved-staging/Cafe\u{0301}.md"),
                reason: .durabilityFailed,
                recoveryState: .retained(
                    relativePath: ".plainsong-create-👩🏽‍💻"
                ),
                recoveryExpectation: fixture.expectation(
                    inode: 11,
                    kind: .regularFile
                ),
                publicationSourceRelativePath: ".plainsong-create-👩🏽‍💻",
                actualPublishedExpectation: fixture.expectation(
                    inode: 12,
                    kind: .regularFile
                )
            ))
        )
        let relocation = fixture.record(
            updatedAt: Date(timeIntervalSince1970: 2),
            payload: .relocation(.init(
                sourceRelativePath: "草稿/e\u{0301}.md",
                destinationRelativePath: "Published/é.md",
                expectation: fixture.expectation(inode: 20, kind: .regularFile),
                sourceParentExpectation:
                fixture.expectation(inode: 21, kind: .directory),
                destinationParentExpectation:
                fixture.expectation(inode: 22, kind: .directory),
                sourceParentBookmarkData:
                Data("source-parent-bookmark".utf8),
                sourceParentDisplayURL:
                URL(fileURLWithPath: "/tmp/moved-drafts"),
                sourceLeafName: "e\u{0301}.md",
                sourceParentAuthorityExpectation:
                fixture.expectation(inode: 24, kind: .directory),
                destinationParentBookmarkData:
                Data("destination-parent-bookmark".utf8),
                destinationParentDisplayURL:
                URL(fileURLWithPath: "/tmp/moved-archive"),
                destinationLeafName: "e\u{0301}.md",
                destinationParentAuthorityExpectation:
                fixture.expectation(inode: 25, kind: .directory),
                relocatedItemBookmarkData: Data("relocated-item-bookmark".utf8),
                relocatedItemDisplayURL:
                URL(fileURLWithPath: "/tmp/moved-archive/e\u{0301}.md"),
                sessionCommitPhase: .committedCleanup,
                reason: .rollbackFailed,
                actualMovedExpectation:
                fixture.expectation(inode: 23, kind: .regularFile)
            ))
        )
        let trash = fixture.record(
            updatedAt: Date(timeIntervalSince1970: 3),
            payload: .trash(.init(
                sourceRelativePath: "Drafts/🧪.md",
                expectation: fixture.expectation(inode: 30, kind: .regularFile),
                sourceParentExpectation: fixture.expectation(inode: 31, kind: .directory),
                sourceParentBookmarkData: Data("trash-source-parent".utf8),
                sourceParentDisplayURL: URL(fileURLWithPath: "/tmp/moved-drafts"),
                sourceLeafName: "🧪.md",
                sourceParentAuthorityExpectation:
                fixture.expectation(inode: 33, kind: .directory),
                expectedItemBookmarkData: Data("expected-item-bookmark".utf8),
                expectedItemDisplayURL:
                URL(fileURLWithPath: "/tmp/escaped-staging/🧪.md"),
                sessionCommitPhase: .committedCleanup,
                reason: .recyclerFailed,
                recoveryRelativePath: ".plainsong-trash-123",
                reportedTrashURL: URL(fileURLWithPath: "/tmp/Trash/post.md"),
                reportedTrashBookmarkData: Data("trash-bookmark".utf8),
                cleanupState: .removalIndeterminate(
                    relativePath: ".plainsong-trash-123"
                ),
                actualStagedExpectation:
                fixture.expectation(inode: 32, kind: .regularFile),
                actualStagedEntryRecoveryRelativePath: "Drafts/🧪.md"
            )),
            textRecoveryRecords: [
                WorkspaceMutationTextRecoveryRecord(
                    originalURL: URL(fileURLWithPath: "/tmp/post.md"),
                    fileKind: .markdown,
                    source: "Exact e\u{0301} 👩🏽‍💻",
                    revision: 7,
                    reason: .indeterminateMutation
                ),
            ]
        )

        try fixture.store.upsert(creation)
        try fixture.store.upsert(relocation)
        try fixture.store.upsert(trash)
        let reloaded = WorkspaceMutationOperationRecoveryStore(
            directoryURL: fixture.directoryURL
        )

        XCTAssertEqual(try reloaded.load(), [creation, relocation, trash])
    }

    func testDecodesLegacyRelocationWithoutParentLocatorsOrDurablePhase() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let legacyCompatibleRecord = fixture.record(
            payload: .relocation(.init(
                sourceRelativePath: "draft.md",
                destinationRelativePath: "archive/draft.md",
                expectation: fixture.expectation(inode: 20, kind: .regularFile),
                sourceParentExpectation:
                fixture.expectation(inode: 21, kind: .directory),
                destinationParentExpectation:
                fixture.expectation(inode: 22, kind: .directory),
                reason: .namespaceChanged,
                actualMovedExpectation: nil
            ))
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let encoded = try encoder.encode(legacyCompatibleRecord)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(encodedText.contains("sourceParentBookmarkData"))
        XCTAssertFalse(encodedText.contains("sourceParentDisplayURL"))
        XCTAssertFalse(encodedText.contains("sourceLeafName"))
        XCTAssertFalse(encodedText.contains("sourceParentAuthorityExpectation"))
        XCTAssertFalse(encodedText.contains("destinationParentBookmarkData"))
        XCTAssertFalse(encodedText.contains("destinationParentDisplayURL"))
        XCTAssertFalse(encodedText.contains("destinationLeafName"))
        XCTAssertFalse(encodedText.contains("destinationParentAuthorityExpectation"))
        XCTAssertFalse(encodedText.contains("relocatedItemBookmarkData"))
        XCTAssertFalse(encodedText.contains("relocatedItemDisplayURL"))
        XCTAssertFalse(encodedText.contains("sessionCommitPhase"))
        XCTAssertEqual(
            try PropertyListDecoder().decode(
                WorkspaceMutationOperationRecoveryRecord.self,
                from: encoded
            ),
            legacyCompatibleRecord
        )
        guard case let .relocation(relocation) = legacyCompatibleRecord.payload else {
            return XCTFail("Expected relocation record")
        }
        XCTAssertNil(relocation.sourceParentBookmarkData)
        XCTAssertNil(relocation.sourceParentDisplayURL)
        XCTAssertNil(relocation.sourceLeafName)
        XCTAssertNil(relocation.sourceParentAuthorityExpectation)
        XCTAssertEqual(
            relocation.sourceLocatorParentExpectation,
            relocation.sourceParentExpectation
        )
        XCTAssertNil(relocation.destinationParentBookmarkData)
        XCTAssertNil(relocation.destinationParentDisplayURL)
        XCTAssertNil(relocation.destinationLeafName)
        XCTAssertNil(relocation.destinationParentAuthorityExpectation)
        XCTAssertEqual(
            relocation.destinationLocatorParentExpectation,
            relocation.destinationParentExpectation
        )
        XCTAssertNil(relocation.relocatedItemBookmarkData)
        XCTAssertNil(relocation.relocatedItemDisplayURL)
        XCTAssertNil(relocation.sessionCommitPhase)
    }

    @MainActor
    func testDecodesLegacyCreationWithoutLocatorsAndMapsPhaseToUnknown() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let record = fixture.record(payload: .creation(.init(
            destinationRelativePath: "draft.md",
            kind: .file,
            parentExpectation: fixture.expectation(inode: 1, kind: .directory),
            isPlanned: true,
            expectedCreatedItem: nil,
            reason: .namespaceChanged,
            recoveryState: .none,
            recoveryExpectation: nil,
            publicationSourceRelativePath: ".plainsong-create-legacy",
            actualPublishedExpectation: nil
        )))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let encoded = try encoder.encode(record)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(encodedText.contains("destinationParentBookmarkData"))
        XCTAssertFalse(encodedText.contains("destinationParentDisplayURL"))
        XCTAssertFalse(encodedText.contains("destinationLeafName"))
        XCTAssertFalse(encodedText.contains("destinationParentAuthorityExpectation"))
        XCTAssertFalse(encodedText.contains("createdItemBookmarkData"))
        XCTAssertFalse(encodedText.contains("createdItemDisplayURL"))
        XCTAssertFalse(encodedText.contains("publicationPhase"))

        let decoded = try PropertyListDecoder().decode(
            WorkspaceMutationOperationRecoveryRecord.self,
            from: encoded
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )
        let recovery = try appState.workspaceMutationRecoveryContext(
            from: decoded,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                sourceParentLocation: nil,
                destinationParentLocation: nil,
                relocatedItemLocation: nil,
                trashExpectedItemLocation: nil,
                trashSourceParentLocation: nil,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .creation(context) = recovery else {
            return XCTFail("Expected creation recovery")
        }
        XCTAssertEqual(context.publicationState, .unknown)
        XCTAssertNil(context.destinationParentBookmarkData)
        XCTAssertNil(context.createdItemBookmarkData)
    }

    func testDecodesLegacyTrashWithoutExpectedItemLocatorOrDurablePhase() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let legacyCompatibleRecord = fixture.record(payload: .trash(.init(
            sourceRelativePath: "draft.md",
            expectation: fixture.expectation(inode: 30, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 31, kind: .directory),
            reason: .namespaceChanged,
            recoveryRelativePath: ".plainsong-trash-123",
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            cleanupState: .removalIndeterminate(
                relativePath: ".plainsong-trash-123"
            ),
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryRelativePath: nil
        )))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let encoded = try encoder.encode(legacyCompatibleRecord)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(encodedText.contains("expectedItemBookmarkData"))
        XCTAssertFalse(encodedText.contains("expectedItemDisplayURL"))
        XCTAssertFalse(encodedText.contains("sourceParentBookmarkData"))
        XCTAssertFalse(encodedText.contains("sourceParentDisplayURL"))
        XCTAssertFalse(encodedText.contains("sourceLeafName"))
        XCTAssertFalse(encodedText.contains("sourceParentAuthorityExpectation"))
        XCTAssertFalse(encodedText.contains("sessionCommitPhase"))
        let decoded = try PropertyListDecoder().decode(
            WorkspaceMutationOperationRecoveryRecord.self,
            from: encoded
        )
        XCTAssertEqual(decoded, legacyCompatibleRecord)
        guard case let .trash(trash) = decoded.payload else {
            return XCTFail("Expected Trash record")
        }
        XCTAssertNil(trash.expectedItemBookmarkData)
        XCTAssertNil(trash.expectedItemDisplayURL)
        XCTAssertNil(trash.sourceParentBookmarkData)
        XCTAssertNil(trash.sourceParentDisplayURL)
        XCTAssertNil(trash.sourceLeafName)
        XCTAssertNil(trash.sourceParentAuthorityExpectation)
        XCTAssertEqual(
            trash.sourceLocatorParentExpectation,
            trash.sourceParentExpectation
        )
        XCTAssertNil(trash.sessionCommitPhase)
    }

    @MainActor
    func testMapsCreationAuthoritiesAndPublicationPhaseBothDirections() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let destinationAuthorityLocation = try rootAuthority.location(
            relativePath: "draft.md"
        )
        let itemAuthorityLocation = try rootAuthority.location(
            relativePath: "archive/draft.md"
        )
        let parentExpectation = WorkspaceMutationOperationRecoveryRecord.Expectation(
            rootAuthority.directoryMutationExpectation
        )
        let itemExpectation = fixture.expectation(inode: 42, kind: .regularFile)
        let creation = WorkspaceMutationOperationRecoveryRecord.Creation(
            destinationRelativePath: "draft.md",
            kind: .file,
            parentExpectation: parentExpectation,
            destinationParentBookmarkData: Data("creation-parent".utf8),
            destinationParentDisplayURL: fixture.containerURL,
            destinationLeafName: "draft.md",
            destinationParentAuthorityExpectation: parentExpectation,
            publicationPhase: .committedCleanup,
            isPlanned: false,
            expectedCreatedItem: itemExpectation,
            createdItemBookmarkData: Data("creation-item".utf8),
            createdItemDisplayURL: fixture.containerURL.appendingPathComponent("draft.md"),
            reason: .namespaceChanged,
            recoveryState: .none,
            recoveryExpectation: nil,
            publicationSourceRelativePath: ".plainsong-create-42",
            actualPublishedExpectation: nil
        )
        let record = fixture.record(payload: .creation(creation))
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                creationDestinationParentLocation: destinationAuthorityLocation,
                creationCreatedItemLocation: itemAuthorityLocation,
                sourceParentLocation: nil,
                destinationParentLocation: nil,
                relocatedItemLocation: nil,
                trashExpectedItemLocation: nil,
                trashSourceParentLocation: nil,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .creation(context) = recovery else {
            return XCTFail("Expected creation recovery")
        }
        XCTAssertEqual(context.publicationState, .committed)
        XCTAssertEqual(
            context.destinationParentAuthorityLocation,
            destinationAuthorityLocation
        )
        XCTAssertEqual(context.createdItemAuthorityLocation, itemAuthorityLocation)
        XCTAssertEqual(
            appState.workspaceMutationOperationRecoveryPayload(for: recovery),
            .creation(creation)
        )
    }

    @MainActor
    func testRestartRefreshesStaleCreationParentAndItemAuthorities() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let postsURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: postsURL,
            withIntermediateDirectories: false
        )
        let stagingURL = fixture.containerURL.appendingPathComponent(
            ".plainsong-create-stale"
        )
        try Data("Prepared".utf8).write(to: stagingURL)
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: postsURL
        ).directoryMutationExpectation
        let itemExpectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: stagingURL)
        )
        let rootBookmark = try ProductionMutationBookmarkAccess().makeBookmark(
            for: fixture.containerURL
        )
        let staleParent = Data("stale-creation-parent".utf8)
        let freshParent = Data("fresh-creation-parent".utf8)
        let staleItem = Data("stale-creation-item".utf8)
        let freshItem = Data("fresh-creation-item".utf8)
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            rootBookmarkData: rootBookmark,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: .creation(.init(
                destinationRelativePath: "posts/draft.md",
                kind: .file,
                parentExpectation: .init(parentExpectation),
                destinationParentBookmarkData: staleParent,
                destinationParentDisplayURL: URL(fileURLWithPath: "/tmp/old-posts"),
                destinationLeafName: "draft.md",
                destinationParentAuthorityExpectation: .init(parentExpectation),
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem: .init(itemExpectation),
                createdItemBookmarkData: staleItem,
                createdItemDisplayURL: URL(fileURLWithPath: "/tmp/old-staging"),
                reason: .namespaceChanged,
                recoveryState: .retained(relativePath: ".plainsong-create-stale"),
                recoveryExpectation: .init(itemExpectation),
                publicationSourceRelativePath: ".plainsong-create-stale",
                actualPublishedExpectation: nil
            )),
            textRecoveryRecords: []
        )
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [freshParent, freshItem],
            resolutions: [
                staleParent: .init(fileURL: postsURL, isStale: true),
                freshParent: .init(fileURL: postsURL, isStale: false),
                staleItem: .init(fileURL: stagingURL, isStale: true),
                freshItem: .init(fileURL: stagingURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        try fixture.store.upsert(record)

        let recovery = try appState.restoreWorkspaceMutationOperationRecovery(record)

        guard case let .creation(context) = recovery else {
            return XCTFail("Expected creation recovery")
        }
        XCTAssertEqual(context.publicationState, .prepared)
        XCTAssertNotNil(context.destinationParentAuthorityLocation)
        XCTAssertNotNil(context.createdItemAuthorityLocation)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .creation(creation) = persisted.payload else {
            return XCTFail("Expected creation payload")
        }
        XCTAssertEqual(creation.destinationParentBookmarkData, freshParent)
        XCTAssertEqual(creation.createdItemBookmarkData, freshItem)
        XCTAssertEqual(bookmarkAccess.resolveCallData, [
            staleParent,
            freshParent,
            staleItem,
            freshItem,
        ])
    }

    @MainActor
    func testRestartKeepsPresentButUnresolvedCreationLocatorsFailClosed() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let rootBookmark = try ProductionMutationBookmarkAccess().makeBookmark(
            for: fixture.containerURL
        )
        let parentBookmark = Data("unresolved-creation-parent".utf8)
        let itemBookmark = Data("unresolved-creation-item".utf8)
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            rootBookmarkData: rootBookmark,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: .creation(.init(
                destinationRelativePath: "draft.md",
                kind: .file,
                parentExpectation: .init(rootAuthority.directoryMutationExpectation),
                destinationParentBookmarkData: parentBookmark,
                destinationParentDisplayURL: fixture.containerURL,
                destinationLeafName: "draft.md",
                destinationParentAuthorityExpectation:
                .init(rootAuthority.directoryMutationExpectation),
                publicationPhase: .prepared,
                isPlanned: true,
                expectedCreatedItem:
                fixture.expectation(inode: 90, kind: .regularFile),
                createdItemBookmarkData: itemBookmark,
                createdItemDisplayURL:
                fixture.containerURL.appendingPathComponent(".plainsong-create-90"),
                reason: .namespaceChanged,
                recoveryState: .retained(relativePath: ".plainsong-create-90"),
                recoveryExpectation:
                fixture.expectation(inode: 90, kind: .regularFile),
                publicationSourceRelativePath: ".plainsong-create-90",
                actualPublishedExpectation: nil
            )),
            textRecoveryRecords: []
        )
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.restoreWorkspaceMutationOperationRecovery(record)

        guard case let .creation(context) = recovery else {
            return XCTFail("Expected creation recovery")
        }
        XCTAssertEqual(context.publicationState, .prepared)
        XCTAssertEqual(context.destinationParentBookmarkData, parentBookmark)
        XCTAssertNil(context.destinationParentAuthorityLocation)
        XCTAssertTrue(context.destinationParentAuthorityIsUnresolved)
        XCTAssertEqual(context.createdItemBookmarkData, itemBookmark)
        XCTAssertNil(context.createdItemAuthorityLocation)
        XCTAssertTrue(context.createdItemAuthorityIsUnresolved)
    }

    @MainActor
    func testCreationCallbackRejectsUnresolvedExactItemAuthorityBeforePublication() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let plan = try WorkspaceFileOperations().makeFileCreationPlan(
            named: "draft.md",
            inDirectoryRelativePath: "",
            rootAuthority: rootAuthority,
            expectingDirectory: rootAuthority.directoryMutationExpectation
        )
        let staging = try XCTUnwrap(plan.stagingLocation)
        try Data("Prepared".utf8).write(to: staging.fileURL)
        let stagingExpectation = try WorkspaceNoFollowItemInspector.inspect(at: staging)
        let replacementURL = fixture.containerURL.appendingPathComponent("replacement.md")
        try Data("Replacement".utf8).write(to: replacementURL)
        let parentBookmark = Data("creation-parent".utf8)
        let wrongItemBookmark = Data("wrong-creation-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [parentBookmark, wrongItemBookmark],
            resolutions: [
                parentBookmark: .init(fileURL: fixture.containerURL, isStale: false),
                wrongItemBookmark: .init(fileURL: replacementURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        var intent = try appState.prepareWorkspaceCreationRecoveryIntent(
            plan: plan,
            kind: .file
        )

        XCTAssertThrowsError(
            try appState.recordWorkspaceCreatedArtifact(
                WorkspacePreparedItemCreationArtifact(
                    location: staging,
                    expectation: stagingExpectation
                ),
                recoveryIntent: &intent
            )
        )

        XCTAssertEqual(intent.publicationState, .planned)
        XCTAssertNil(intent.expectedCreatedItem)
        XCTAssertNil(intent.createdItemBookmarkData)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .creation(creation) = persisted.payload else {
            return XCTFail("Expected creation payload")
        }
        XCTAssertEqual(creation.publicationPhase, .planned)
        XCTAssertNil(creation.expectedCreatedItem)
        XCTAssertNil(creation.createdItemBookmarkData)
    }

    @MainActor
    func testCreationCallbackUpsertFailureKeepsPreparedIntentForFinishRetry() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let plan = try WorkspaceFileOperations().makeFileCreationPlan(
            named: "draft.md",
            inDirectoryRelativePath: "",
            rootAuthority: rootAuthority,
            expectingDirectory: rootAuthority.directoryMutationExpectation
        )
        let staging = try XCTUnwrap(plan.stagingLocation)
        try Data("Prepared".utf8).write(to: staging.fileURL)
        let stagingExpectation = try WorkspaceNoFollowItemInspector.inspect(at: staging)
        let parentBookmark = Data("creation-parent".utf8)
        let itemBookmark = Data("creation-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [parentBookmark, itemBookmark],
            resolutions: [
                parentBookmark: .init(fileURL: fixture.containerURL, isStale: false),
                itemBookmark: .init(fileURL: staging.fileURL, isStale: false),
            ]
        )
        let store = FailingNthUpsertWorkspaceMutationOperationRecoveryStore(
            failingUpsert: 2
        )
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: store,
            workspaceMutationTextRecoveryStore: WorkspaceMutationTextRecoveryStore(
                directoryURL: fixture.containerURL.appendingPathComponent(
                    "TextRecovery",
                    isDirectory: true
                )
            ),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
        var intent = try appState.prepareWorkspaceCreationRecoveryIntent(
            plan: plan,
            kind: .file
        )

        XCTAssertThrowsError(
            try appState.recordWorkspaceCreatedArtifact(
                WorkspacePreparedItemCreationArtifact(
                    location: staging,
                    expectation: stagingExpectation
                ),
                recoveryIntent: &intent
            )
        )
        XCTAssertEqual(intent.publicationState, .prepared)
        XCTAssertEqual(intent.expectedCreatedItem, stagingExpectation)
        XCTAssertEqual(intent.createdItemBookmarkData, itemBookmark)
        guard case let .creation(planned) = try XCTUnwrap(store.load().first).payload else {
            return XCTFail("Expected creation payload")
        }
        XCTAssertEqual(planned.publicationPhase, .planned)
        XCTAssertNil(planned.createdItemBookmarkData)

        XCTAssertThrowsError(
            try appState.finishWorkspaceCreation(
                .creationStateIndeterminate(.init(
                    destination: plan.destination,
                    reason: .commitPreparationFailed,
                    recoveryState: .retained(staging),
                    createdExpectation: stagingExpectation,
                    recoveryExpectation: stagingExpectation,
                    publicationSource: staging,
                    actualPublishedExpectation: nil
                )),
                recoveryIntent: intent
            )
        )

        guard case let .creation(prepared) = try XCTUnwrap(store.load().first).payload else {
            return XCTFail("Expected creation payload")
        }
        XCTAssertEqual(prepared.publicationPhase, .prepared)
        XCTAssertEqual(prepared.expectedCreatedItem, .init(stagingExpectation))
        XCTAssertEqual(prepared.createdItemBookmarkData, itemBookmark)
    }

    @MainActor
    func testMapsRelocationItemAuthorityAndDurablePhaseBothDirections() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let relocatedAuthorityLocation = try rootAuthority.location(
            relativePath: "escaped/draft.md"
        )
        let sourceParentAuthorityLocation = try rootAuthority.location(
            relativePath: "source-slot/draft.md"
        )
        let destinationParentAuthorityLocation = try rootAuthority.location(
            relativePath: "destination-slot/draft.md"
        )
        let itemBookmark = Data("item-bookmark".utf8)
        let itemDisplayURL = URL(fileURLWithPath: "/tmp/escaped/draft.md")
        let sourceAuthorityExpectation = fixture.expectation(
            inode: 24,
            kind: .directory
        )
        let destinationAuthorityExpectation = fixture.expectation(
            inode: 25,
            kind: .directory
        )
        let relocation = WorkspaceMutationOperationRecoveryRecord.Relocation(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            sourceParentBookmarkData: Data("source-parent".utf8),
            sourceParentDisplayURL: URL(fileURLWithPath: "/tmp/source-slot"),
            sourceLeafName: "draft.md",
            sourceParentAuthorityExpectation: sourceAuthorityExpectation,
            destinationParentBookmarkData: Data("destination-parent".utf8),
            destinationParentDisplayURL:
            URL(fileURLWithPath: "/tmp/destination-slot"),
            destinationLeafName: "draft.md",
            destinationParentAuthorityExpectation: destinationAuthorityExpectation,
            relocatedItemBookmarkData: itemBookmark,
            relocatedItemDisplayURL: itemDisplayURL,
            sessionCommitPhase: .committedCleanup,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )
        let record = fixture.record(payload: .relocation(relocation))
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                sourceParentLocation: sourceParentAuthorityLocation,
                destinationParentLocation: destinationParentAuthorityLocation,
                relocatedItemLocation: relocatedAuthorityLocation,
                trashExpectedItemLocation: nil,
                trashSourceParentLocation: nil,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .relocation(context) = recovery else {
            return XCTFail("Expected relocation recovery")
        }
        XCTAssertEqual(context.relocatedItemBookmarkData, itemBookmark)
        XCTAssertEqual(context.relocatedItemDisplayURL, itemDisplayURL)
        XCTAssertEqual(context.relocatedItemAuthorityLocation, relocatedAuthorityLocation)
        XCTAssertEqual(
            context.sourceParentAuthorityExpectation,
            sourceAuthorityExpectation.runtimeValue
        )
        XCTAssertEqual(
            context.sourceParentAuthorityLocation,
            sourceParentAuthorityLocation
        )
        XCTAssertEqual(
            context.destinationParentAuthorityExpectation,
            destinationAuthorityExpectation.runtimeValue
        )
        XCTAssertEqual(
            context.destinationParentAuthorityLocation,
            destinationParentAuthorityLocation
        )
        XCTAssertEqual(context.sessionCommitState, .committed)
        XCTAssertEqual(
            appState.workspaceMutationOperationRecoveryPayload(for: recovery),
            .relocation(relocation)
        )
    }

    @MainActor
    func testLegacyRelocationPhaseMapsToUnknownSessionCommitState() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                sourceParentLocation: nil,
                destinationParentLocation: nil,
                relocatedItemLocation: nil,
                trashExpectedItemLocation: nil,
                trashSourceParentLocation: nil,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .relocation(context) = recovery else {
            return XCTFail("Expected relocation recovery")
        }
        XCTAssertEqual(context.sessionCommitState, .unknown)
    }

    @MainActor
    func testMapsTrashExpectedItemAuthorityAndDurablePhaseBothDirections() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let expectedItemLocation = try rootAuthority.location(
            relativePath: ".plainsong-trash-123/draft.md"
        )
        let sourceParentLocation = try rootAuthority.location(
            relativePath: "source-slot/draft.md"
        )
        let expectedItemBookmark = Data("expected-item".utf8)
        let expectedItemDisplayURL = URL(
            fileURLWithPath: "/tmp/moved-staging/draft.md"
        )
        let sourceParentExpectation = fixture.expectation(
            inode: 33,
            kind: .directory
        )
        let trash = WorkspaceMutationOperationRecoveryRecord.Trash(
            sourceRelativePath: "draft.md",
            expectation: fixture.expectation(inode: 30, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 31, kind: .directory),
            sourceParentBookmarkData: Data("trash-source-parent".utf8),
            sourceParentDisplayURL: URL(fileURLWithPath: "/tmp/source-slot"),
            sourceLeafName: "draft.md",
            sourceParentAuthorityExpectation: sourceParentExpectation,
            expectedItemBookmarkData: expectedItemBookmark,
            expectedItemDisplayURL: expectedItemDisplayURL,
            sessionCommitPhase: .committedCleanup,
            reason: .namespaceChanged,
            recoveryRelativePath: ".plainsong-trash-123/draft.md",
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            cleanupState: .removalIndeterminate(
                relativePath: ".plainsong-trash-123/draft.md"
            ),
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryRelativePath: nil
        )
        let record = fixture.record(payload: .trash(trash))
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                sourceParentLocation: nil,
                destinationParentLocation: nil,
                relocatedItemLocation: nil,
                trashExpectedItemLocation: expectedItemLocation,
                trashSourceParentLocation: sourceParentLocation,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .trash(context) = recovery else {
            return XCTFail("Expected Trash recovery")
        }
        XCTAssertEqual(context.expectedItemBookmarkData, expectedItemBookmark)
        XCTAssertEqual(context.expectedItemDisplayURL, expectedItemDisplayURL)
        XCTAssertEqual(context.expectedItemAuthorityLocation, expectedItemLocation)
        XCTAssertEqual(
            context.sourceParentAuthorityExpectation,
            sourceParentExpectation.runtimeValue
        )
        XCTAssertEqual(context.sourceParentAuthorityLocation, sourceParentLocation)
        XCTAssertFalse(context.expectedItemAuthorityIsUnresolved)
        XCTAssertEqual(context.sessionCommitState, .committed)
        XCTAssertEqual(
            appState.workspaceMutationOperationRecoveryPayload(for: recovery),
            .trash(trash)
        )
    }

    @MainActor
    func testLegacyTrashPhaseMapsToUnknownSessionCommitState() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let record = fixture.record(payload: .trash(.init(
            sourceRelativePath: "draft.md",
            expectation: fixture.expectation(inode: 30, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 31, kind: .directory),
            reason: .namespaceChanged,
            recoveryRelativePath: nil,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            cleanupState: .notCreated,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryRelativePath: nil
        )))
        let appState = fixture.appState(
            bookmarkAccess: RecordingWorkspaceMutationBookmarkAuthorityAccess()
        )

        let recovery = try appState.workspaceMutationRecoveryContext(
            from: record,
            rootAuthority: rootAuthority,
            restoredAuthorities: .init(
                sourceParentLocation: nil,
                destinationParentLocation: nil,
                relocatedItemLocation: nil,
                trashExpectedItemLocation: nil,
                trashSourceParentLocation: nil,
                reportedTrashLocation: nil,
                reportedTrashDisplayURL: nil
            )
        )

        guard case let .trash(context) = recovery else {
            return XCTFail("Expected Trash recovery")
        }
        XCTAssertEqual(context.sessionCommitState, .unknown)
    }

    @MainActor
    func testPrepareTrashRecoveryPersistsSourceSlotAndExpectedItemInSingleIntent() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let postsURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        let stagingURL = fixture.containerURL.appendingPathComponent(
            ".plainsong-trash-stage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        let sourceURL = postsURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: sourceURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: sourceURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let sourceParentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: postsURL
        ).directoryMutationExpectation
        let sourceParentBookmark = Data("trash-source-parent".utf8)
        let expectedItemBookmark = Data("trash-expected-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [sourceParentBookmark, expectedItemBookmark],
            resolutions: [
                sourceParentBookmark: .init(fileURL: postsURL, isStale: false),
                expectedItemBookmark: .init(fileURL: sourceURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let source = try rootAuthority.location(relativePath: "posts/draft.md")
        let staging = try rootAuthority.location(
            relativePath: ".plainsong-trash-stage/draft.md"
        )
        let initial = WorkspaceTrashRecoveryContext(
            id: UUID(),
            source: source,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            reason: .namespaceChanged,
            recoveryLocation: staging,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .removalIndeterminate(staging),
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )

        let prepared = try appState.prepareWorkspaceTrashRecoveryIntent(initial)

        XCTAssertEqual(prepared.sessionCommitState, .pending)
        XCTAssertEqual(prepared.sourceParentBookmarkData, sourceParentBookmark)
        XCTAssertEqual(prepared.sourceParentDisplayURL, postsURL)
        XCTAssertEqual(prepared.sourceLeafName, "draft.md")
        XCTAssertEqual(prepared.sourceParentAuthorityLocation?.rootURL, postsURL)
        XCTAssertEqual(prepared.expectedItemBookmarkData, expectedItemBookmark)
        XCTAssertEqual(prepared.expectedItemAuthorityLocation?.fileURL, sourceURL)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .trash(trash) = persisted.payload else {
            return XCTFail("Expected Trash record")
        }
        XCTAssertEqual(trash.sourceParentBookmarkData, sourceParentBookmark)
        XCTAssertEqual(trash.sourceLeafName, "draft.md")
        XCTAssertEqual(trash.expectedItemBookmarkData, expectedItemBookmark)
        XCTAssertEqual(trash.sessionCommitPhase, .pendingSessionCommit)
        XCTAssertEqual(bookmarkAccess.makeCallURLs, [postsURL, sourceURL])
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [sourceParentBookmark, expectedItemBookmark]
        )
    }

    @MainActor
    func testPrepareTrashRecoveryDoesNotPersistWhenExpectedItemCaptureChanges() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let postsURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: false)
        let sourceURL = postsURL.appendingPathComponent("draft.md")
        let replacementURL = postsURL.appendingPathComponent("replacement.md")
        try Data("Original".utf8).write(to: sourceURL)
        try Data("Replacement".utf8).write(to: replacementURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: sourceURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let sourceParentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: postsURL
        ).directoryMutationExpectation
        let sourceParentBookmark = Data("trash-source-parent".utf8)
        let changedItemBookmark = Data("changed-trash-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [sourceParentBookmark, changedItemBookmark],
            resolutions: [
                sourceParentBookmark: .init(fileURL: postsURL, isStale: false),
                changedItemBookmark: .init(fileURL: replacementURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let source = try rootAuthority.location(relativePath: "posts/draft.md")
        let initial = WorkspaceTrashRecoveryContext(
            id: UUID(),
            source: source,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .notCreated,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )

        XCTAssertThrowsError(try appState.prepareWorkspaceTrashRecoveryIntent(initial))
        XCTAssertEqual(try fixture.store.load(), [])
    }

    @MainActor
    func testPrepareTrashCommittedRecoveryPersistsVerifiedReportedAuthority() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let reportedTrashURL = fixture.containerURL.appendingPathComponent(
            "reported-trash.md"
        )
        try Data("Original".utf8).write(to: reportedTrashURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: reportedTrashURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let reportedBookmark = Data("reported-trash".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [reportedBookmark],
            resolutions: [
                reportedBookmark: .init(fileURL: reportedTrashURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let source = try rootAuthority.location(relativePath: "reported-trash.md")
        let pending = WorkspaceTrashRecoveryContext(
            id: UUID(),
            source: source,
            expectation: expectation,
            sourceParentExpectation: rootAuthority.directoryMutationExpectation,
            sessionCommitState: .pending,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .removed,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )

        let committed = try appState.prepareWorkspaceTrashCommittedRecovery(
            pending,
            reportedTrashURL: reportedTrashURL
        )

        XCTAssertEqual(committed.sessionCommitState, .committed)
        XCTAssertEqual(committed.reportedTrashBookmarkData, reportedBookmark)
        XCTAssertEqual(committed.reportedTrashAuthorityLocation?.fileURL, reportedTrashURL)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .trash(trash) = persisted.payload else {
            return XCTFail("Expected Trash record")
        }
        XCTAssertEqual(trash.sessionCommitPhase, .committedCleanup)
        XCTAssertEqual(trash.reportedTrashBookmarkData, reportedBookmark)
    }

    @MainActor
    func testRestartRestoresTrashSourceSlotAndExpectedItemAfterParentMoves() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let originalParentURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        let movedParentURL = fixture.containerURL.appendingPathComponent(
            "escaped-posts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalParentURL,
            withIntermediateDirectories: false
        )
        let originalItemURL = originalParentURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: originalItemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: originalItemURL)
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: originalParentURL
        ).directoryMutationExpectation
        try FileManager.default.moveItem(at: originalParentURL, to: movedParentURL)
        let movedItemURL = movedParentURL.appendingPathComponent("draft.md")
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let rootBookmarkData = try ProductionMutationBookmarkAccess().makeBookmark(
            for: fixture.containerURL
        )
        let parentBookmark = Data("moved-trash-parent".utf8)
        let expectedItemBookmark = Data("moved-trash-item".utf8)
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: .trash(.init(
                sourceRelativePath: "posts/draft.md",
                expectation: .init(expectation),
                sourceParentExpectation: .init(parentExpectation),
                sourceParentBookmarkData: parentBookmark,
                sourceParentDisplayURL: originalParentURL,
                sourceLeafName: "draft.md",
                sourceParentAuthorityExpectation: .init(parentExpectation),
                expectedItemBookmarkData: expectedItemBookmark,
                expectedItemDisplayURL: originalItemURL,
                sessionCommitPhase: .pendingSessionCommit,
                reason: .namespaceChanged,
                recoveryRelativePath: nil,
                reportedTrashURL: nil,
                reportedTrashBookmarkData: nil,
                cleanupState: .removed,
                actualStagedExpectation: nil,
                actualStagedEntryRecoveryRelativePath: nil
            )),
            textRecoveryRecords: []
        )
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                parentBookmark: .init(fileURL: movedParentURL, isStale: false),
                expectedItemBookmark: .init(fileURL: movedItemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        try fixture.store.upsert(record)

        let recovery = try appState.restoreWorkspaceMutationOperationRecovery(record)

        guard case let .trash(context) = recovery else {
            return XCTFail("Expected Trash recovery")
        }
        XCTAssertEqual(context.sourceParentAuthorityLocation?.rootURL, movedParentURL)
        XCTAssertEqual(context.sourceParentAuthorityLocation?.relativePath, "draft.md")
        XCTAssertEqual(context.expectedItemAuthorityLocation?.fileURL, movedItemURL)
        XCTAssertFalse(context.expectedItemAuthorityIsUnresolved)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .trash(trash) = persisted.payload else {
            return XCTFail("Expected persisted Trash record")
        }
        XCTAssertEqual(trash.sourceParentDisplayURL, movedParentURL)
        XCTAssertEqual(trash.expectedItemDisplayURL, movedItemURL)
    }

    @MainActor
    func testRestartKeepsPresentButUnresolvedTrashItemLocatorFailClosed() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let rootBookmarkData = try ProductionMutationBookmarkAccess().makeBookmark(
            for: fixture.containerURL
        )
        let staleBookmark = Data("stale-trash-item".utf8)
        let stillStaleBookmark = Data("still-stale-trash-item".utf8)
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: .trash(.init(
                sourceRelativePath: "draft.md",
                expectation: .init(expectation),
                sourceParentExpectation: .init(
                    rootAuthority.directoryMutationExpectation
                ),
                expectedItemBookmarkData: staleBookmark,
                expectedItemDisplayURL: itemURL,
                sessionCommitPhase: .pendingSessionCommit,
                reason: .namespaceChanged,
                recoveryRelativePath: nil,
                reportedTrashURL: nil,
                reportedTrashBookmarkData: nil,
                cleanupState: .removed,
                actualStagedExpectation: nil,
                actualStagedEntryRecoveryRelativePath: nil
            )),
            textRecoveryRecords: []
        )
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [stillStaleBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: itemURL, isStale: true),
                stillStaleBookmark: .init(fileURL: itemURL, isStale: true),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        let recovery = try appState.restoreWorkspaceMutationOperationRecovery(record)

        guard case let .trash(context) = recovery else {
            return XCTFail("Expected Trash recovery")
        }
        XCTAssertEqual(context.expectedItemBookmarkData, staleBookmark)
        XCTAssertNil(context.expectedItemAuthorityLocation)
        XCTAssertTrue(context.expectedItemAuthorityIsUnresolved)
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, stillStaleBookmark]
        )
    }

    @MainActor
    func testResolveTrashAuthoritiesRefreshesDurableBookmarkOnEveryCheck() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let postsURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: false)
        let itemURL = postsURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: postsURL
        ).directoryMutationExpectation
        let parentBookmark = Data("trash-source-parent".utf8)
        let staleItemBookmark = Data("stale-trash-item".utf8)
        let refreshedItemBookmark = Data("refreshed-trash-item".utf8)
        let record = fixture.record(payload: .trash(.init(
            sourceRelativePath: "posts/draft.md",
            expectation: .init(expectation),
            sourceParentExpectation: .init(parentExpectation),
            sourceParentBookmarkData: parentBookmark,
            sourceParentDisplayURL: postsURL,
            sourceLeafName: "draft.md",
            sourceParentAuthorityExpectation: .init(parentExpectation),
            expectedItemBookmarkData: staleItemBookmark,
            expectedItemDisplayURL: itemURL,
            sessionCommitPhase: .pendingSessionCommit,
            reason: .namespaceChanged,
            recoveryRelativePath: nil,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            cleanupState: .removed,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryRelativePath: nil
        )))
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [refreshedItemBookmark],
            resolutions: [
                parentBookmark: .init(fileURL: postsURL, isStale: false),
                staleItemBookmark: .init(fileURL: itemURL, isStale: true),
                refreshedItemBookmark: .init(fileURL: itemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let source = try rootAuthority.location(relativePath: "posts/draft.md")
        let installed = WorkspaceTrashRecoveryContext(
            id: record.id,
            source: source,
            expectation: expectation,
            sourceParentExpectation: parentExpectation,
            sessionCommitState: .pending,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .removed,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )
        try fixture.store.upsert(record)
        appState.workspaceMutationOperationRecoveryRecords[record.id] = record

        let resolved = try appState.resolveWorkspaceTrashAuthorities(installed)

        XCTAssertEqual(resolved.sourceParentAuthorityLocation?.rootURL, postsURL)
        XCTAssertEqual(resolved.expectedItemBookmarkData, refreshedItemBookmark)
        XCTAssertEqual(resolved.expectedItemAuthorityLocation?.fileURL, itemURL)
        guard case let .trash(refreshedRecord) = try XCTUnwrap(
            fixture.store.load().first
        ).payload else {
            return XCTFail("Expected Trash record")
        }
        XCTAssertEqual(refreshedRecord.expectedItemBookmarkData, refreshedItemBookmark)

        bookmarkAccess.resolutions[refreshedItemBookmark] = nil
        let unresolved = try appState.resolveWorkspaceTrashAuthorities(resolved)

        XCTAssertEqual(unresolved.expectedItemBookmarkData, refreshedItemBookmark)
        XCTAssertNil(unresolved.expectedItemAuthorityLocation)
        XCTAssertTrue(unresolved.expectedItemAuthorityIsUnresolved)
    }

    @MainActor
    func testReportedTrashCaptureRejectsBookmarkThatResolvesToDifferentIdentity() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let expectedURL = fixture.containerURL.appendingPathComponent("expected.md")
        let replacementURL = fixture.containerURL.appendingPathComponent("replacement.md")
        try Data("Expected".utf8).write(to: expectedURL)
        try Data("Replacement".utf8).write(to: replacementURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: expectedURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let bookmarkData = Data("reported-trash-race".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [bookmarkData],
            resolutions: [
                bookmarkData: .init(fileURL: replacementURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let source = try rootAuthority.location(relativePath: "expected.md")
        var context = WorkspaceTrashRecoveryContext(
            id: UUID(),
            source: source,
            expectation: expectation,
            sourceParentExpectation: rootAuthority.directoryMutationExpectation,
            reason: .namespaceChanged,
            recoveryLocation: nil,
            reportedTrashURL: expectedURL,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .removed,
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: [],
            remainingSessionIDs: []
        )

        context = appState
            .workspaceTrashRecoveryContextCapturingReportedAuthorityIfPossible(context)

        XCTAssertNil(context.reportedTrashBookmarkData)
        XCTAssertNil(context.reportedTrashAuthorityLocation)
        XCTAssertEqual(bookmarkAccess.makeCallURLs, [expectedURL])
        XCTAssertEqual(bookmarkAccess.resolveCallData, [bookmarkData])
    }

    @MainActor
    func testRestartRestoreInstallsItemAuthorityAndPersistsChangedDisplayURL() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let postsURL = fixture.containerURL.appendingPathComponent(
            "posts",
            isDirectory: true
        )
        let archiveURL = fixture.containerURL.appendingPathComponent(
            "archive",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        let itemURL = postsURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let itemExpectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let rootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.containerURL
        )
        let sourceParentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: postsURL
        ).directoryMutationExpectation
        let destinationParentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: archiveURL
        ).directoryMutationExpectation
        let rootBookmarkData = try ProductionMutationBookmarkAccess().makeBookmark(
            for: fixture.containerURL
        )
        let itemBookmarkData = Data("item-bookmark".utf8)
        let recordedDisplayURL = URL(fileURLWithPath: "/tmp/old-parent/draft.md")
        let record = WorkspaceMutationOperationRecoveryRecord(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            rootBookmarkData: rootBookmarkData,
            rootDisplayURL: rootAuthority.canonicalRootURL,
            rootExpectation: .init(rootAuthority.directoryMutationExpectation),
            payload: .relocation(.init(
                sourceRelativePath: "posts/draft.md",
                destinationRelativePath: "archive/draft.md",
                expectation: .init(itemExpectation),
                sourceParentExpectation: .init(sourceParentExpectation),
                destinationParentExpectation: .init(destinationParentExpectation),
                relocatedItemBookmarkData: itemBookmarkData,
                relocatedItemDisplayURL: recordedDisplayURL,
                sessionCommitPhase: .committedCleanup,
                reason: .namespaceChanged,
                actualMovedExpectation: nil
            )),
            textRecoveryRecords: []
        )
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                itemBookmarkData: .init(fileURL: itemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        try fixture.store.upsert(record)

        let recovery = try appState.restoreWorkspaceMutationOperationRecovery(record)

        guard case let .relocation(context) = recovery else {
            return XCTFail("Expected relocation recovery")
        }
        XCTAssertEqual(context.relocatedItemAuthorityLocation?.fileURL.path, itemURL.path)
        XCTAssertEqual(context.relocatedItemDisplayURL?.path, itemURL.path)
        XCTAssertEqual(context.sessionCommitState, .committed)
        let persisted = try XCTUnwrap(fixture.store.load().first)
        guard case let .relocation(persistedRelocation) = persisted.payload else {
            return XCTFail("Expected persisted relocation")
        }
        XCTAssertEqual(persistedRelocation.relocatedItemBookmarkData, itemBookmarkData)
        XCTAssertEqual(persistedRelocation.relocatedItemDisplayURL?.path, itemURL.path)
        XCTAssertEqual(persistedRelocation.sessionCommitPhase, .committedCleanup)
        XCTAssertEqual(bookmarkAccess.resolveCallData, [itemBookmarkData])
    }

    @MainActor
    func testCapturesRelocatedItemBookmarkAsExactStandaloneAuthority() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let itemLocation = try WorkspaceFileSystemLocation(fileURL: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(at: itemLocation)
        let bookmarkData = Data("item-bookmark".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [bookmarkData],
            resolutions: [
                bookmarkData: .init(fileURL: itemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        let captured = try appState.captureWorkspaceMutationItemBookmarkAuthority(
            at: itemURL,
            expecting: expectation
        )

        XCTAssertEqual(captured.location, itemLocation)
        XCTAssertEqual(captured.bookmarkData, bookmarkData)
        XCTAssertEqual(captured.displayURL, itemURL)
        XCTAssertEqual(bookmarkAccess.makeCallURLs, [itemURL])
        XCTAssertEqual(bookmarkAccess.resolveCallData, [bookmarkData])
    }

    @MainActor
    func testCaptureRefreshesAndRevalidatesStaleRelocatedItemBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let staleBookmark = Data("stale-item".utf8)
        let refreshedBookmark = Data("refreshed-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [staleBookmark, refreshedBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: itemURL, isStale: true),
                refreshedBookmark: .init(fileURL: itemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        let captured = try appState.captureWorkspaceMutationItemBookmarkAuthority(
            at: itemURL,
            expecting: expectation
        )

        XCTAssertEqual(captured.bookmarkData, refreshedBookmark)
        XCTAssertEqual(bookmarkAccess.makeCallURLs, [itemURL, itemURL])
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, refreshedBookmark]
        )
    }

    @MainActor
    func testCaptureRelocatedItemBookmarkRejectsDifferentIdentity() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        let replacementURL = fixture.containerURL.appendingPathComponent("replacement.md")
        try Data("Original".utf8).write(to: itemURL)
        try Data("Replacement".utf8).write(to: replacementURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let bookmarkData = Data("wrong-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [bookmarkData],
            resolutions: [
                bookmarkData: .init(fileURL: replacementURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        XCTAssertThrowsError(
            try appState.captureWorkspaceMutationItemBookmarkAuthority(
                at: itemURL,
                expecting: expectation
            )
        )
    }

    @MainActor
    func testRestoresRelocatedItemBookmarkAfterParentMoves() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let originalParentURL = fixture.containerURL
            .appendingPathComponent("posts", isDirectory: true)
        let movedParentURL = fixture.containerURL
            .appendingPathComponent("escaped-posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originalParentURL,
            withIntermediateDirectories: false
        )
        let originalItemURL = originalParentURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: originalItemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: originalItemURL)
        )
        try FileManager.default.moveItem(at: originalParentURL, to: movedParentURL)
        let movedItemURL = movedParentURL.appendingPathComponent("draft.md")
        let bookmarkData = Data("moved-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                bookmarkData: .init(fileURL: movedItemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "posts/draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: .init(expectation),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            relocatedItemBookmarkData: bookmarkData,
            relocatedItemDisplayURL: originalItemURL,
            sessionCommitPhase: .pendingSessionCommit,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationItemAuthority(from: record)

        let location = try XCTUnwrap(restored.location)
        XCTAssertEqual(location.fileURL.path, movedItemURL.path)
        XCTAssertEqual(restored.refreshedBookmarkData, bookmarkData)
        XCTAssertEqual(restored.displayURL, movedItemURL)
        XCTAssertEqual(bookmarkAccess.resolveCallData, [bookmarkData])
    }

    @MainActor
    func testRelocatedItemRestoreRefreshesAndRevalidatesStaleBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let staleBookmark = Data("stale-item".utf8)
        let refreshedBookmark = Data("refreshed-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [refreshedBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: itemURL, isStale: true),
                refreshedBookmark: .init(fileURL: itemURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: .init(expectation),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            relocatedItemBookmarkData: staleBookmark,
            relocatedItemDisplayURL: itemURL,
            sessionCommitPhase: .pendingSessionCommit,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationItemAuthority(from: record)

        XCTAssertNotNil(restored.location)
        XCTAssertEqual(restored.refreshedBookmarkData, refreshedBookmark)
        XCTAssertEqual(restored.displayURL, itemURL)
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, refreshedBookmark]
        )
    }

    @MainActor
    func testRelocatedItemRestoreFailsClosedWhenRefreshedBookmarkRemainsStale() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let itemURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: itemURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: itemURL)
        )
        let staleBookmark = Data("stale-item".utf8)
        let stillStaleBookmark = Data("still-stale-item".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [stillStaleBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: itemURL, isStale: true),
                stillStaleBookmark: .init(fileURL: itemURL, isStale: true),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: .init(expectation),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            relocatedItemBookmarkData: staleBookmark,
            relocatedItemDisplayURL: itemURL,
            sessionCommitPhase: .pendingSessionCommit,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationItemAuthority(from: record)

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, stillStaleBookmark]
        )
    }

    @MainActor
    func testRelocatedItemRestoreNeverUsesDisplayURLWithoutBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let displayURL = fixture.containerURL.appendingPathComponent("draft.md")
        try Data("Original".utf8).write(to: displayURL)
        let expectation = try WorkspaceNoFollowItemInspector.inspect(
            at: WorkspaceFileSystemLocation(fileURL: displayURL)
        )
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess()
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: .init(expectation),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            relocatedItemDisplayURL: displayURL,
            sessionCommitPhase: .pendingSessionCommit,
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationItemAuthority(from: record)

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
        XCTAssertTrue(bookmarkAccess.resolveCallData.isEmpty)
    }

    @MainActor
    func testCapturesDestinationParentBookmarkAsChildRootAuthority() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let destinationParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: destinationParentURL
        ).directoryMutationExpectation
        let bookmarkData = Data("archive-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [bookmarkData],
            resolutions: [
                bookmarkData: .init(
                    fileURL: destinationParentURL,
                    isStale: false
                ),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        let captured = try appState.captureWorkspaceMutationBookmarkAuthority(
            at: destinationParentURL,
            destinationLeafName: "Cafe\u{0301}.md",
            expectingParent: parentExpectation
        )

        XCTAssertEqual(captured.bookmarkData, bookmarkData)
        XCTAssertEqual(captured.displayURL, destinationParentURL)
        XCTAssertEqual(captured.location.rootURL, destinationParentURL)
        XCTAssertEqual(captured.location.relativePath, "Cafe\u{0301}.md")
        XCTAssertEqual(
            captured.location.rootAuthority.directoryMutationExpectation,
            parentExpectation
        )
        XCTAssertEqual(bookmarkAccess.makeCallURLs, [destinationParentURL])
        XCTAssertEqual(bookmarkAccess.resolveCallData, [bookmarkData])
    }

    @MainActor
    func testCaptureRefreshesAndRevalidatesStaleParentBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let destinationParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: destinationParentURL
        ).directoryMutationExpectation
        let staleBookmark = Data("stale-parent".utf8)
        let refreshedBookmark = Data("refreshed-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [staleBookmark, refreshedBookmark],
            resolutions: [
                staleBookmark: .init(
                    fileURL: destinationParentURL,
                    isStale: true
                ),
                refreshedBookmark: .init(
                    fileURL: destinationParentURL,
                    isStale: false
                ),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        let captured = try appState.captureWorkspaceMutationBookmarkAuthority(
            at: destinationParentURL,
            destinationLeafName: "draft.md",
            expectingParent: parentExpectation
        )

        XCTAssertEqual(captured.bookmarkData, refreshedBookmark)
        XCTAssertEqual(captured.location.rootURL, destinationParentURL)
        XCTAssertEqual(captured.location.relativePath, "draft.md")
        XCTAssertEqual(
            bookmarkAccess.makeCallURLs,
            [destinationParentURL, destinationParentURL]
        )
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, refreshedBookmark]
        )
    }

    @MainActor
    func testCaptureRejectsRefreshedBookmarkThatRemainsStale() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let destinationParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: destinationParentURL
        ).directoryMutationExpectation
        let staleBookmark = Data("stale-parent".utf8)
        let stillStaleBookmark = Data("still-stale-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [staleBookmark, stillStaleBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: destinationParentURL, isStale: true),
                stillStaleBookmark: .init(
                    fileURL: destinationParentURL,
                    isStale: true
                ),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)

        XCTAssertThrowsError(
            try appState.captureWorkspaceMutationBookmarkAuthority(
                at: destinationParentURL,
                destinationLeafName: "draft.md",
                expectingParent: parentExpectation
            )
        )
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, stillStaleBookmark]
        )
    }

    @MainActor
    func testRestoresBothParentEntryLocatorsUsingEffectiveExpectations() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let originalSourceParentURL = fixture.containerURL
            .appendingPathComponent("original-source", isDirectory: true)
        let originalDestinationParentURL = fixture.containerURL
            .appendingPathComponent("original-destination", isDirectory: true)
        let activeSourceParentURL = fixture.containerURL
            .appendingPathComponent("active-source", isDirectory: true)
        let activeDestinationParentURL = fixture.containerURL
            .appendingPathComponent("active-destination", isDirectory: true)
        for parentURL in [
            originalSourceParentURL,
            originalDestinationParentURL,
            activeSourceParentURL,
            activeDestinationParentURL,
        ] {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: false
            )
        }
        let originalSourceExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: originalSourceParentURL
        ).directoryMutationExpectation
        let originalDestinationExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: originalDestinationParentURL
        ).directoryMutationExpectation
        let activeSourceExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: activeSourceParentURL
        ).directoryMutationExpectation
        let activeDestinationExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: activeDestinationParentURL
        ).directoryMutationExpectation
        let sourceBookmark = Data("active-source-parent".utf8)
        let destinationBookmark = Data("active-destination-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                sourceBookmark: .init(fileURL: activeSourceParentURL, isStale: false),
                destinationBookmark:
                    .init(fileURL: activeDestinationParentURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "original-source/draft.md",
            destinationRelativePath: "original-destination/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: .init(originalSourceExpectation),
            destinationParentExpectation: .init(originalDestinationExpectation),
            sourceParentBookmarkData: sourceBookmark,
            sourceParentDisplayURL: originalSourceParentURL,
            sourceLeafName: "draft.md",
            sourceParentAuthorityExpectation: .init(activeSourceExpectation),
            destinationParentBookmarkData: destinationBookmark,
            destinationParentDisplayURL: originalDestinationParentURL,
            destinationLeafName: "draft.md",
            destinationParentAuthorityExpectation: .init(activeDestinationExpectation),
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restoredSource = appState.restoredRelocationSourceParentAuthority(from: record)
        let restoredDestination =
            appState.restoredRelocationDestinationParentAuthority(from: record)

        XCTAssertEqual(restoredSource.location?.rootURL, activeSourceParentURL)
        XCTAssertEqual(restoredSource.location?.relativePath, "draft.md")
        XCTAssertEqual(restoredSource.refreshedBookmarkData, sourceBookmark)
        XCTAssertEqual(restoredDestination.location?.rootURL, activeDestinationParentURL)
        XCTAssertEqual(restoredDestination.location?.relativePath, "draft.md")
        XCTAssertEqual(restoredDestination.refreshedBookmarkData, destinationBookmark)
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [sourceBookmark, destinationBookmark]
        )
    }

    @MainActor
    func testSourceParentRestoreNeverUsesDisplayURLWithoutBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let sourceParentURL = fixture.containerURL
            .appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceParentURL,
            withIntermediateDirectories: false
        )
        let sourceParentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: sourceParentURL
        ).directoryMutationExpectation
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess()
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "source/draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: .init(sourceParentExpectation),
            destinationParentExpectation:
            fixture.expectation(inode: 22, kind: .directory),
            sourceParentDisplayURL: sourceParentURL,
            sourceLeafName: "draft.md",
            sourceParentAuthorityExpectation: .init(sourceParentExpectation),
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationSourceParentAuthority(from: record)

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
        XCTAssertTrue(bookmarkAccess.resolveCallData.isEmpty)
    }

    @MainActor
    func testRestoresRelocationChildFromBookmarkAfterParentMoves() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let originalParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        let movedParentURL = fixture.containerURL
            .appendingPathComponent("moved-archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originalParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: originalParentURL
        ).directoryMutationExpectation
        try FileManager.default.moveItem(at: originalParentURL, to: movedParentURL)
        let bookmarkData = Data("moved-parent-bookmark".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                bookmarkData: .init(fileURL: movedParentURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/Cafe\u{0301}.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation: .init(parentExpectation),
            destinationParentBookmarkData: bookmarkData,
            destinationParentDisplayURL: originalParentURL,
            destinationLeafName: "Cafe\u{0301}.md",
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))
        try fixture.store.upsert(record)
        let persistedRecord = try XCTUnwrap(fixture.store.load().first)

        let restored = appState.restoredRelocationDestinationParentAuthority(
            from: persistedRecord
        )

        let location = try XCTUnwrap(restored.location)
        XCTAssertEqual(location.rootURL, movedParentURL)
        XCTAssertEqual(location.relativePath, "Cafe\u{0301}.md")
        XCTAssertEqual(restored.refreshedBookmarkData, bookmarkData)
        XCTAssertEqual(restored.displayURL, movedParentURL)
        XCTAssertEqual(bookmarkAccess.resolveCallData, [bookmarkData])
    }

    @MainActor
    func testRelocationRestoreNeverUsesDisplayURLWithoutBookmark() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let destinationParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: destinationParentURL
        ).directoryMutationExpectation
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess()
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation: .init(parentExpectation),
            destinationParentBookmarkData: nil,
            destinationParentDisplayURL: destinationParentURL,
            destinationLeafName: "draft.md",
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationDestinationParentAuthority(
            from: record
        )

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
        XCTAssertTrue(bookmarkAccess.resolveCallData.isEmpty)
    }

    @MainActor
    func testRelocationRestoreRejectsBookmarkForDifferentParentIdentity() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let expectedParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        let differentParentURL = fixture.containerURL
            .appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(
            at: expectedParentURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: differentParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: expectedParentURL
        ).directoryMutationExpectation
        let bookmarkData = Data("wrong-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            resolutions: [
                bookmarkData: .init(fileURL: differentParentURL, isStale: false),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation: .init(parentExpectation),
            destinationParentBookmarkData: bookmarkData,
            destinationParentDisplayURL: expectedParentURL,
            destinationLeafName: "draft.md",
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationDestinationParentAuthority(
            from: record
        )

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
    }

    @MainActor
    func testRelocationRestoreFailsClosedWhenStaleRefreshCannotBeRevalidated() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let destinationParentURL = fixture.containerURL
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: false
        )
        let parentExpectation = try WorkspaceFileSystemRootAuthority(
            rootURL: destinationParentURL
        ).directoryMutationExpectation
        let staleBookmark = Data("stale-parent".utf8)
        let stillStaleBookmark = Data("still-stale-parent".utf8)
        let bookmarkAccess = RecordingWorkspaceMutationBookmarkAuthorityAccess(
            bookmarkDataQueue: [stillStaleBookmark],
            resolutions: [
                staleBookmark: .init(fileURL: destinationParentURL, isStale: true),
                stillStaleBookmark: .init(
                    fileURL: destinationParentURL,
                    isStale: true
                ),
            ]
        )
        let appState = fixture.appState(bookmarkAccess: bookmarkAccess)
        let record = fixture.record(payload: .relocation(.init(
            sourceRelativePath: "draft.md",
            destinationRelativePath: "archive/draft.md",
            expectation: fixture.expectation(inode: 20, kind: .regularFile),
            sourceParentExpectation: fixture.expectation(inode: 21, kind: .directory),
            destinationParentExpectation: .init(parentExpectation),
            destinationParentBookmarkData: staleBookmark,
            destinationParentDisplayURL: destinationParentURL,
            destinationLeafName: "draft.md",
            reason: .namespaceChanged,
            actualMovedExpectation: nil
        )))

        let restored = appState.restoredRelocationDestinationParentAuthority(
            from: record
        )

        XCTAssertNil(restored.location)
        XCTAssertNil(restored.refreshedBookmarkData)
        XCTAssertNil(restored.displayURL)
        XCTAssertEqual(
            bookmarkAccess.resolveCallData,
            [staleBookmark, stillStaleBookmark]
        )
    }

    func testUpsertAtomicallyReplacesOneOperationRecord() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let original = fixture.record(
            id: id,
            payload: fixture.creationPayload(reason: .namespaceChanged)
        )
        let updated = fixture.record(
            id: id,
            updatedAt: Date(timeIntervalSince1970: 2),
            payload: fixture.creationPayload(reason: .durabilityFailed)
        )

        try fixture.store.upsert(original)
        try fixture.store.upsert(updated)

        XCTAssertEqual(try fixture.store.load(), [updated])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path),
            [WorkspaceMutationOperationRecoveryStore.recordFilename(for: id)]
        )
    }

    func testLoadPreservesCorruptRecordAndSurfacesFailure() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let retained = fixture.record(payload: fixture.creationPayload())
        try fixture.store.upsert(retained)
        let corruptURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationOperationRecoveryStore.recordFilename(for: UUID())
        )
        try Data("not a plist".utf8).write(to: corruptURL)

        XCTAssertThrowsError(try fixture.store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testDirectoryLevelLoadFailureIsSurfaced() throws {
        let fixture = try OperationStoreFixture(createDirectory: false)
        defer { fixture.cleanUp() }
        try Data("not a directory".utf8).write(to: fixture.directoryURL)

        XCTAssertThrowsError(try fixture.store.load())
    }

    func testRemoveIsIdempotent() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let record = fixture.record(payload: fixture.creationPayload())
        try fixture.store.upsert(record)

        try fixture.store.remove(id: record.id)
        try fixture.store.remove(id: record.id)

        XCTAssertEqual(try fixture.store.load(), [])
    }

    func testUpsertCreatesMissingRecoveryDirectoryThroughSharedDurableHelper() throws {
        let fixture = try OperationStoreFixture(createDirectory: false)
        defer { fixture.cleanUp() }
        let record = fixture.record(payload: fixture.creationPayload())

        try fixture.store.upsert(record)

        XCTAssertEqual(try fixture.store.load(), [record])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directoryURL.path
        ))
    }

    func testDirectoryHierarchySynchronizesEveryNewDirectoryEdge() throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMutationRecoveryDurabilityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let applicationSupportURL = containerURL
            .appendingPathComponent("Application Support", isDirectory: true)
        let plainsongURL = applicationSupportURL
            .appendingPathComponent("Plainsong", isDirectory: true)
        let recoveryURL = plainsongURL
            .appendingPathComponent("WorkspaceMutationOperationRecovery", isDirectory: true)
        var events: [WorkspaceMutationRecoveryDurableFileStore.Event] = []

        try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
            recoveryURL,
            existingHierarchyDurabilityBoundaryURL: applicationSupportURL,
            eventHandler: { events.append($0) }
        )

        XCTAssertEqual(events, [
            .directoryCreated(applicationSupportURL),
            .directorySynchronized(applicationSupportURL),
            .directorySynchronized(containerURL),
            .directoryCreated(plainsongURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(applicationSupportURL),
            .directoryCreated(recoveryURL),
            .directorySynchronized(recoveryURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(recoveryURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(applicationSupportURL),
        ])

        events.removeAll()
        try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
            recoveryURL,
            existingHierarchyDurabilityBoundaryURL: applicationSupportURL,
            eventHandler: { events.append($0) }
        )
        XCTAssertEqual(events, [
            .directorySynchronized(recoveryURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(applicationSupportURL),
        ])
    }

    func testDirectoryHierarchyRetryResynchronizesPreviouslyCreatedParentEdges() throws {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMutationRecoveryRetryTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: containerURL) }
        let applicationSupportURL = containerURL
            .appendingPathComponent("Application Support", isDirectory: true)
        let plainsongURL = applicationSupportURL
            .appendingPathComponent("Plainsong", isDirectory: true)
        let recoveryURL = plainsongURL
            .appendingPathComponent("WorkspaceMutationOperationRecovery", isDirectory: true)
        var synchronizationCount = 0

        XCTAssertThrowsError(
            try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
                recoveryURL,
                existingHierarchyDurabilityBoundaryURL: applicationSupportURL,
                descriptorSynchronizer: { descriptor in
                    synchronizationCount += 1
                    if synchronizationCount == 4 {
                        errno = EIO
                        return -1
                    }
                    return Darwin.fsync(descriptor)
                }
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: plainsongURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))

        var retryEvents: [WorkspaceMutationRecoveryDurableFileStore.Event] = []
        try WorkspaceMutationRecoveryDurableFileStore.ensureDirectoryHierarchy(
            recoveryURL,
            existingHierarchyDurabilityBoundaryURL: applicationSupportURL,
            eventHandler: { retryEvents.append($0) }
        )

        XCTAssertEqual(retryEvents, [
            .directoryCreated(recoveryURL),
            .directorySynchronized(recoveryURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(recoveryURL),
            .directorySynchronized(plainsongURL),
            .directorySynchronized(applicationSupportURL),
        ])
    }

    func testRemoveMissingRecordSynchronizesDirectoryBeforeSuccess() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let missingURL = fixture.directoryURL.appendingPathComponent(
            WorkspaceMutationOperationRecoveryStore.recordFilename(for: UUID()),
            isDirectory: false
        )
        var events: [WorkspaceMutationRecoveryDurableFileStore.Event] = []

        try WorkspaceMutationRecoveryDurableFileStore.remove(
            missingURL,
            directoryURL: fixture.directoryURL,
            eventHandler: { events.append($0) }
        )

        XCTAssertEqual(events, [
            .directorySynchronized(fixture.directoryURL),
        ])
    }

    func testQuarantineRetrySynchronizesParentAfterPriorRenameFsyncFailure() throws {
        let fixture = try OperationStoreFixture()
        defer { fixture.cleanUp() }
        let record = fixture.record(payload: fixture.creationPayload())
        try fixture.store.upsert(record)

        XCTAssertThrowsError(
            try WorkspaceMutationRecoveryDurableFileStore.quarantineRecoveryDirectory(
                fixture.directoryURL,
                descriptorSynchronizer: { _ in
                    errno = EIO
                    return -1
                }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directoryURL.path
        ))
        var retryEvents: [WorkspaceMutationRecoveryDurableFileStore.Event] = []

        let result =
            try WorkspaceMutationRecoveryDurableFileStore
                .quarantineRecoveryDirectory(
                    fixture.directoryURL,
                    eventHandler: { retryEvents.append($0) }
                )

        XCTAssertNil(result)
        XCTAssertEqual(retryEvents, [
            .directorySynchronized(fixture.containerURL),
        ])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.containerURL.path
            ).filter { $0.contains("-unreadable-") }.count,
            1
        )
    }
}

private final class OperationStoreFixture {
    let containerURL: URL
    let directoryURL: URL
    let store: WorkspaceMutationOperationRecoveryStore

    init(createDirectory: Bool = true) throws {
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMutationOperationRecoveryStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        directoryURL = containerURL.appendingPathComponent("Recovery", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } else {
            try FileManager.default.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
        }
        store = WorkspaceMutationOperationRecoveryStore(directoryURL: directoryURL)
    }

    func record(
        id: UUID = UUID(),
        updatedAt: Date = Date(timeIntervalSince1970: 1),
        payload: WorkspaceMutationOperationRecoveryRecord.Payload,
        textRecoveryRecords: [WorkspaceMutationTextRecoveryRecord] = []
    ) -> WorkspaceMutationOperationRecoveryRecord {
        WorkspaceMutationOperationRecoveryRecord(
            id: id,
            updatedAt: updatedAt,
            rootBookmarkData: Data("bookmark".utf8),
            rootDisplayURL: URL(fileURLWithPath: "/tmp/workspace"),
            rootExpectation: expectation(inode: 1, kind: .directory),
            payload: payload,
            textRecoveryRecords: textRecoveryRecords
        )
    }

    func creationPayload(
        reason: WorkspaceMutationOperationRecoveryRecord.Failure = .namespaceChanged
    ) -> WorkspaceMutationOperationRecoveryRecord.Payload {
        .creation(.init(
            destinationRelativePath: "post.md",
            kind: .file,
            expectedCreatedItem: expectation(inode: 2, kind: .regularFile),
            reason: reason,
            recoveryState: .retained(relativePath: ".plainsong-create-123"),
            recoveryExpectation: expectation(inode: 2, kind: .regularFile),
            publicationSourceRelativePath: ".plainsong-create-123",
            actualPublishedExpectation: expectation(inode: 3, kind: .regularFile)
        ))
    }

    func expectation(
        inode: UInt64,
        kind: WorkspaceMutationOperationRecoveryRecord.Expectation.Kind
    ) -> WorkspaceMutationOperationRecoveryRecord.Expectation {
        .init(device: 7, inode: inode, kind: kind)
    }

    @MainActor
    func appState(
        bookmarkAccess: any WorkspaceMutationBookmarkAccessing
    ) -> AppState {
        AppState(
            workspaceMutationOperationRecoveryStore: store,
            workspaceMutationTextRecoveryStore: WorkspaceMutationTextRecoveryStore(
                directoryURL: containerURL.appendingPathComponent(
                    "TextRecovery",
                    isDirectory: true
                )
            ),
            reportedTrashBookmarkAccess: bookmarkAccess,
            shouldRestoreLastOpenedFile: false
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: containerURL)
    }
}

private final class RecordingWorkspaceMutationBookmarkAuthorityAccess:
    WorkspaceMutationBookmarkAccessing
{
    var bookmarkDataQueue: [Data]
    var resolutions: [Data: WorkspaceMutationBookmarkResolution]
    private(set) var makeCallURLs: [URL] = []
    private(set) var resolveCallData: [Data] = []

    init(
        bookmarkDataQueue: [Data] = [],
        resolutions: [Data: WorkspaceMutationBookmarkResolution] = [:]
    ) {
        self.bookmarkDataQueue = bookmarkDataQueue
        self.resolutions = resolutions
    }

    func makeBookmark(for fileURL: URL) throws -> Data {
        makeCallURLs.append(fileURL)
        guard !bookmarkDataQueue.isEmpty else {
            throw WorkspaceMutationBookmarkAuthorityTestError.unavailable
        }
        return bookmarkDataQueue.removeFirst()
    }

    func resolveBookmark(
        _ bookmarkData: Data
    ) throws -> WorkspaceMutationBookmarkResolution {
        resolveCallData.append(bookmarkData)
        guard let resolution = resolutions[bookmarkData] else {
            throw WorkspaceMutationBookmarkAuthorityTestError.unavailable
        }
        return resolution
    }
}

private final class FailingNthUpsertWorkspaceMutationOperationRecoveryStore:
    WorkspaceMutationOperationRecoveryPersisting
{
    private let failingUpsert: Int
    private var upsertCount = 0
    private var records: [UUID: WorkspaceMutationOperationRecoveryRecord] = [:]

    init(failingUpsert: Int) {
        self.failingUpsert = failingUpsert
    }

    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws {
        upsertCount += 1
        guard upsertCount != failingUpsert else {
            throw CocoaError(.fileWriteUnknown)
        }
        records[record.id] = record
    }

    func remove(id: UUID) throws {
        records[id] = nil
    }

    func quarantineAfterLoadFailure() throws {}
}

private enum WorkspaceMutationBookmarkAuthorityTestError: Error {
    case unavailable
}
