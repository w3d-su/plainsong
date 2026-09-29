import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Recovery, context-only, and different-authority (workspace subfolder) owners reach the
/// export writer through the same App inventory as Save Copy and workspace mutations.
extension ExportDestinationOwnershipAppTests {
    func testLiveWorkspaceMutationRecoveryCandidateAndItsCaseAliasAreRefused() throws {
        let root = try makeTemporaryDirectory()
        let record = try makeCreationRecoveryRecord(rootURL: root, destinationRelativePath: "Page.html")
        let operationStore = TransientMutationOperationStore()
        operationStore.upsert(record)
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: TransientMutationTextStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.restoreLastOpenedFileIfNeeded()
        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id], "the candidate must be live")
        XCTAssertEqual(
            try appState.exportArtifactDestinationOwnership(
                for: inspection(of: root.appendingPathComponent("unowned.html")),
                exportSource: appState.currentDocument
            ),
            .permitted,
            "control: the refusal below is attributable to the recovery candidate"
        )
        let candidateURL = root.appendingPathComponent("Page.html")

        let outcome = appState.writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: candidateURL,
                kind: .html,
                disposition: .createNew,
                bytes: Data("<p>export</p>".utf8)
            ),
            exportSource: appState.currentDocument
        )

        XCTAssertEqual(outcome, .notCommitted(.ownedDestination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)), [])
        let aliasInspection = try inspection(of: root.appendingPathComponent("page.html"))
        if !aliasInspection.parentIsCaseSensitive {
            XCTAssertEqual(
                appState.exportArtifactDestinationOwnership(
                    for: aliasInspection,
                    exportSource: appState.currentDocument
                ),
                .refused
            )
        }
        XCTAssertNotNil(appState.workspaceMutationRecoveries[record.id])
    }

    func testTextRecoveryOriginalAndContextOnlyOwnersAreRefused() throws {
        let root = try makeTemporaryDirectory()
        let recoveredURL = root.appendingPathComponent("recovered.html")
        let textStore = TransientMutationTextStore()
        textStore.upsert(WorkspaceMutationTextRecoveryRecord(
            originalURL: recoveredURL,
            fileKind: .markdown,
            source: "Recovered source",
            revision: 1,
            reason: .indeterminateMutation
        ))
        // A pending text-recovery record exists from launch until restoration promotes it.
        let appState = AppState(
            workspaceMutationOperationRecoveryStore: TransientMutationOperationStore(),
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )
        XCTAssertEqual(appState.pendingWorkspaceMutationTextRecoveryRecords.map(\.originalURL), [recoveredURL])
        let control = try inspection(of: root.appendingPathComponent("unowned.html"))
        XCTAssertEqual(
            appState.exportArtifactDestinationOwnership(for: control, exportSource: appState.currentDocument),
            .permitted
        )

        let hashedURL = root.appendingPathComponent("hashed.html")
        appState.lastKnownDiskHashes[hashedURL] = "context-only"
        let detachedURL = root.appendingPathComponent("detached.html")
        appState.detachedSessionURLs.insert(detachedURL)

        for owned in [recoveredURL, hashedURL, detachedURL] {
            XCTAssertEqual(
                try appState.exportArtifactDestinationOwnership(
                    for: inspection(of: owned),
                    exportSource: appState.currentDocument
                ),
                .refused,
                owned.lastPathComponent
            )
        }
        XCTAssertEqual(
            appState.exportArtifactDestinationOwnership(for: control, exportSource: appState.currentDocument),
            .permitted
        )
    }

    func testSubfolderExportCollidingByHardLinkIsRefusedAcrossRootAuthorities() throws {
        let fixture = try makeWorkspaceFixture(ownedName: "posts/owned.md")
        let subfolder = fixture.ownedURL.deletingLastPathComponent()
        let exportURL = subfolder.appendingPathComponent("export.html")
        try FileManager.default.linkItem(at: fixture.ownedURL, to: exportURL)
        let exportLocation = try WorkspaceFileSystemLocation(fileURL: exportURL)
        XCTAssertNotEqual(
            exportLocation.rootAuthority,
            fixture.authority,
            "the export parent is its own authority, so ownership compares full paths"
        )
        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: subfolder.appendingPathComponent("unowned.html")),
                exportSource: fixture.ownedSession
            ),
            .permitted
        )
        guard case let .existingRegularFile(approved) = ExportArtifactWriter.inspectDestination(
            at: exportURL,
            kind: .html
        ) else {
            return XCTFail("the hard link must inspect as an existing regular file")
        }

        let outcome = fixture.appState.writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: exportURL,
                kind: .html,
                disposition: .replaceConfirmed(approved),
                bytes: Data("<p>export</p>".utf8)
            ),
            exportSource: fixture.ownedSession
        )

        XCTAssertEqual(outcome, .notCommitted(.ownedDestination))
        XCTAssertEqual(try text(at: fixture.ownedURL), "owned sentinel")
        XCTAssertEqual(try text(at: exportURL), "owned sentinel")
        XCTAssertEqual(try linkCount(at: exportURL), 2)
        XCTAssertEqual(try operationSiblings(in: subfolder), [])
    }

    func testSubfolderCaseAliasOfOwnedMissingFileIsRefusedByFullPathComparison() throws {
        let fixture = try makeWorkspaceFixture(ownedName: "posts/Draft.md")
        let subfolder = fixture.ownedURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: fixture.ownedURL)
        fixture.appState.markSessionDetachedFromMissingFile(fixture.ownedSession, url: fixture.ownedURL)
        let aliasInspection = try inspection(of: subfolder.appendingPathComponent("draft.md"))
        guard !aliasInspection.parentIsCaseSensitive else {
            throw XCTSkip("Case aliases require a case-insensitive test volume")
        }
        XCTAssertNotEqual(aliasInspection.canonicalLocation.rootAuthority, fixture.authority)
        try assertUnownedControlIsPermitted(fixture)

        // The Save Copy inventory alone refuses it, through its different-authority path.
        XCTAssertThrowsError(try fixture.appState.validateWorkspaceSaveCopyDestinationOwnership(
            at: aliasInspection.canonicalLocation,
            excluding: nil
        ))
        XCTAssertEqual(
            fixture.appState.exportArtifactDestinationOwnership(
                for: aliasInspection,
                exportSource: fixture.ownedSession
            ),
            .refused
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: subfolder.path(percentEncoded: false)), [])
    }

    private func makeCreationRecoveryRecord(
        rootURL: URL,
        destinationRelativePath: String
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
            payload: .creation(.init(
                destinationRelativePath: destinationRelativePath,
                kind: .file,
                parentExpectation: nil,
                isPlanned: nil,
                expectedCreatedItem: nil,
                reason: .namespaceChanged,
                recoveryState: .unknown,
                recoveryExpectation: nil,
                publicationSourceRelativePath: nil,
                actualPublishedExpectation: nil
            )),
            textRecoveryRecords: []
        )
    }
}
