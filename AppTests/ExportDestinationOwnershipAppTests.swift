import Darwin
import EditorKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Export PR E: the writer's injected ownership capability reuses the Save Copy / mutation
/// inventory. Fixtures mirror the Save Copy collision shapes (hard link, case alias,
/// detached/quarantined session, recovery-store failure).
@MainActor
final class ExportDestinationOwnershipAppTests: XCTestCase {
    func testHardLinkToCachedAnchoredSessionIsRefusedAndNothingIsWritten() throws {
        let fixture = try makeWorkspaceFixture()
        let exportURL = fixture.root.appendingPathComponent("export.html")
        try FileManager.default.linkItem(at: fixture.ownedURL, to: exportURL)
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
        try assertUnownedControlIsPermitted(fixture)
        XCTAssertEqual(try text(at: fixture.ownedURL), "owned sentinel")
        XCTAssertEqual(try text(at: exportURL), "owned sentinel")
        XCTAssertEqual(try linkCount(at: exportURL), 2)
        XCTAssertEqual(try operationSiblings(in: fixture.root), [])
    }

    func testHardLinkToEveryUnanchoredManagedOwnerIsRefused() throws {
        for placement in ["cached", "retired", "editor-bound"] {
            let fixture = try makeWorkspaceFixture()
            let standaloneRoot = try makeTemporaryDirectory()
            let standaloneURL = standaloneRoot.appendingPathComponent("\(placement).md")
            try writeText("\(placement) sentinel", to: standaloneURL)
            let exportURL = fixture.root.appendingPathComponent("\(placement).html")
            try FileManager.default.linkItem(at: standaloneURL, to: exportURL)
            let session = DocumentSession(
                text: "\(placement) text",
                url: standaloneURL,
                fileKind: .markdown,
                isDirty: true
            )
            switch placement {
            case "cached":
                fixture.appState.sessionCache[standaloneURL] = session
            case "retired":
                fixture.appState.retiredEditorDocumentSessions[standaloneURL] =
                    RetiredEditorDocumentSession(
                        canonicalURL: standaloneURL,
                        session: session,
                        bindingIDs: [EditorDocumentBindingID()],
                        awaitingInstallations: [],
                        securityScopedAuthorityOwners: []
                    )
            default:
                let bindingID = EditorDocumentBindingID()
                fixture.appState.editorDocumentBindingIDs[ObjectIdentifier(session)] = bindingID
                fixture.appState.editorDocumentBindingSessions[bindingID] = session
            }
            fixture.appState.retainUnanchoredManagedSessionOwnership(for: session)
            try assertUnownedControlIsPermitted(fixture)

            let decision = try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: exportURL),
                exportSource: fixture.ownedSession
            )

            XCTAssertEqual(decision, .refused, placement)
            XCTAssertEqual(try text(at: standaloneURL), "\(placement) sentinel", placement)
        }
    }

    func testCaseAliasOfMissingDetachedSessionIsRefused() throws {
        let fixture = try makeWorkspaceFixture(ownedName: "Draft.md")
        try FileManager.default.removeItem(at: fixture.ownedURL)
        fixture.appState.markSessionDetachedFromMissingFile(
            fixture.ownedSession,
            url: fixture.ownedURL
        )
        let aliasURL = fixture.root.appendingPathComponent("draft.md")
        let aliasInspection = try inspection(of: aliasURL)
        guard !aliasInspection.parentIsCaseSensitive else {
            throw XCTSkip("Case aliases require a case-insensitive test volume")
        }

        try assertUnownedControlIsPermitted(fixture)
        XCTAssertEqual(
            fixture.appState.exportArtifactDestinationOwnership(
                for: aliasInspection,
                exportSource: fixture.ownedSession
            ),
            .refused
        )
        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: fixture.ownedURL),
                exportSource: fixture.ownedSession
            ),
            .refused
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasURL.path(percentEncoded: false)))
    }

    func testQuarantinedIndeterminateSaveCopyDestinationIsRefused() throws {
        let fixture = try makeWorkspaceFixture()
        let quarantinedURL = fixture.root.appendingPathComponent("quarantined.html")
        let quarantinedLocation = try fixture.authority.location(relativePath: "quarantined.html")
        let session = DocumentSession(
            text: "quarantined text",
            url: quarantinedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let sessionIdentity = ObjectIdentifier(session)
        fixture.appState.sessionCache[quarantinedURL] = session
        fixture.appState.indeterminateSessionWrites[sessionIdentity] = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        fixture.appState.indeterminateSessionWriteContexts[sessionIdentity] =
            IndeterminateSessionWriteContext(
                location: quarantinedLocation,
                preparedSHA256Digest: String(repeating: "0", count: 64)
            )
        try assertUnownedControlIsPermitted(fixture)

        let outcome = fixture.appState.writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: quarantinedURL,
                kind: .html,
                disposition: .createNew,
                bytes: Data("<p>export</p>".utf8)
            ),
            exportSource: fixture.ownedSession
        )

        XCTAssertEqual(outcome, .notCommitted(.ownedDestination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedURL.path(percentEncoded: false)))
        XCTAssertEqual(try operationSiblings(in: fixture.root), [])
    }

    func testRecoveryStoreLoadFailureRefusesEveryExportDestination() throws {
        let fixture = try makeWorkspaceFixture()
        let exportURL = fixture.root.appendingPathComponent("unowned.html")
        try assertUnownedControlIsPermitted(fixture)
        fixture.appState.workspaceMutationOperationRecoveryLoadFailed = true

        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: exportURL),
                exportSource: fixture.ownedSession
            ),
            .refused
        )
    }

    func testUnownedDestinationCommitsAndOnlyAFileLessSourceIsExempt() throws {
        let untitledApp = AppState(shouldRestoreLastOpenedFile: false)
        let root = try makeTemporaryDirectory()
        let exportURL = root.appendingPathComponent("untitled.html")

        XCTAssertEqual(
            try untitledApp.exportArtifactDestinationOwnership(
                for: inspection(of: exportURL),
                exportSource: nil
            ),
            .refused,
            "without the source exemption the untitled session's unavailable proof fails closed"
        )
        let outcome = untitledApp.writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: exportURL,
                kind: .html,
                disposition: .createNew,
                bytes: Data("<p>untitled</p>".utf8)
            ),
            exportSource: untitledApp.currentDocument
        )
        guard case .committed = outcome else {
            return XCTFail("an unowned destination must commit: \(outcome)")
        }
        XCTAssertEqual(try text(at: exportURL), "<p>untitled</p>")
        XCTAssertEqual(try operationSiblings(in: root), [])

        let fixture = try makeWorkspaceFixture()
        try assertUnownedControlIsPermitted(fixture)
        let sourceLink = fixture.root.appendingPathComponent("source.html")
        try FileManager.default.linkItem(at: fixture.ownedURL, to: sourceLink)
        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: sourceLink),
                exportSource: fixture.ownedSession
            ),
            .refused,
            "a file-backed export source is never exempt from its own ownership"
        )
    }

    func testDisagreeingWriterInspectionIsRefused() throws {
        let fixture = try makeWorkspaceFixture()
        let exportURL = fixture.root.appendingPathComponent("race.html")
        let missing = try inspection(of: exportURL)
        XCTAssertEqual(
            fixture.appState.exportArtifactDestinationOwnership(for: missing, exportSource: fixture.ownedSession),
            .permitted
        )
        try writeText("appeared after the writer's inspection", to: exportURL)

        XCTAssertEqual(
            fixture.appState.exportArtifactDestinationOwnership(
                for: missing,
                exportSource: fixture.ownedSession
            ),
            .refused
        )
        XCTAssertEqual(try text(at: exportURL), "appeared after the writer's inspection")
    }
}

// MARK: - Fixtures

extension ExportDestinationOwnershipAppTests {
    /// Proves a refusal is attributable to the owner under test, not to an unrelated
    /// fail-closed inventory member.
    func assertUnownedControlIsPermitted(
        _ fixture: WorkspaceFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try fixture.appState.exportArtifactDestinationOwnership(
                for: inspection(of: fixture.root.appendingPathComponent("unowned-control.html")),
                exportSource: fixture.ownedSession
            ),
            .permitted,
            file: file,
            line: line
        )
    }

    struct WorkspaceFixture {
        let root: URL
        let authority: WorkspaceFileSystemRootAuthority
        let appState: AppState
        let ownedURL: URL
        let ownedSession: DocumentSession
    }

    /// A workspace whose current document is the `ownedName` file, bound to a cached anchored
    /// session (the Save Copy ownership fixture shape). No untitled session is in the inventory.
    func makeWorkspaceFixture(ownedName: String = "owned.md") throws -> WorkspaceFixture {
        let root = try makeTemporaryDirectory()
        let ownedURL = root.appendingPathComponent(ownedName)
        try FileManager.default.createDirectory(
            at: ownedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText("owned sentinel", to: ownedURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let ownedLocation = try authority.location(relativePath: ownedName)
        let ownedRead = try MarkdownFileStore().loadResult(at: ownedLocation)
        let ownedSession = DocumentSession(
            text: "owned dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: ownedSession, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[ownedURL] = ownedSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(ownedSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: ownedLocation,
                identity: ownedRead.metadata.identity,
                sha256Digest: ownedRead.sha256Digest
            )
        return WorkspaceFixture(
            root: root,
            authority: authority,
            appState: appState,
            ownedURL: ownedURL,
            ownedSession: ownedSession
        )
    }

    /// Canonical container-temporary directory: the writer refuses symlinked parent paths.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportDestinationOwnershipAppTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    /// The same no-follow inspection the writer passes to its ownership capability.
    func inspection(of url: URL) throws -> WorkspaceNoFollowFileTargetInspection {
        try WorkspaceNoFollowFileInspector.inspectFileTarget(
            at: WorkspaceFileSystemLocation(fileURL: url)
        )
    }

    func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func text(at url: URL) throws -> String {
        try XCTUnwrap(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    func linkCount(at url: URL) throws -> Int {
        var status = stat()
        guard url.path(percentEncoded: false).withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(status.st_nlink)
    }

    func operationSiblings(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix(".plainsong-") }
    }
}
