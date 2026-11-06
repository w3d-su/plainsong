import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// A save the writer refuses before staging (an unsupported, full, or read-only disk, or a
/// denied write) is an ordinary proven non-commit. The session stays dirty and bound, nothing
/// is retained, no external-change read starts, and the user sees the cause.
@MainActor
final class AppStateSaveRefusalTests: XCTestCase {
    func testWriterRefusalKeepsTheSessionDirtyAndStartsNoExternalChangeRead() throws {
        let refusals: [(WorkspaceAnchoredFileSystemError, (URL) -> MarkdownFileStoreError)] = [
            (.unsupportedVolume, MarkdownFileStoreError.unsupportedVolume),
            (.insufficientSpace, MarkdownFileStoreError.insufficientSpace),
            (.readOnlyVolume, MarkdownFileStoreError.readOnlyVolume),
            (.writeNotPermitted, MarkdownFileStoreError.writeNotPermitted),
        ]
        for (reason, expectedError) in refusals {
            let fixture = try makeBoundSessionFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.appState.anchoredFileSaveOverride = { _, _, _ in
                .notCommitted(WorkspaceNotCommittedFileWrite(reason: reason, artifactState: .none))
            }

            XCTAssertThrowsError(try fixture.appState.save(session: fixture.session)) { error in
                XCTAssertEqual(error as? MarkdownFileStoreError, expectedError(fixture.post))
            }

            let sessionIdentity = ObjectIdentifier(fixture.session)
            XCTAssertTrue(fixture.session.isDirty, "\(reason)")
            XCTAssertEqual(fixture.appState.anchoredSessionFileBinding(for: fixture.session), fixture.binding)
            XCTAssertNil(fixture.appState.indeterminateSessionWrites[sessionIdentity])
            XCTAssertNil(fixture.appState.externalDiskInspectionTasks[sessionIdentity], "\(reason)")
            XCTAssertTrue(fixture.appState.fileWriteArtifactNotices.isEmpty)
            XCTAssertEqual(try String(contentsOf: fixture.post, encoding: .utf8), "disk A")
        }
    }

    func testSaveCommandPresentsTheUnsupportedVolumeCause() throws {
        let fixture = try makeBoundSessionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.anchoredFileSaveOverride = { _, _, _ in
            .notCommitted(WorkspaceNotCommittedFileWrite(reason: .unsupportedVolume, artifactState: .none))
        }

        fixture.appState.save()

        let presented = try XCTUnwrap(fixture.appState.presentedError)
        XCTAssertEqual(presented.title, "Could Not Save File")
        XCTAssertEqual(
            presented.message,
            MarkdownFileStoreError.unsupportedVolume(fixture.post).localizedDescription
        )
        XCTAssertTrue(presented.message.contains("exFAT"))
        XCTAssertTrue(fixture.session.isDirty)
    }

    private struct BoundSessionFixture {
        let root: URL
        let post: URL
        let session: DocumentSession
        let binding: AnchoredWorkspaceSessionFileBinding
        let appState: AppState
    }

    private func makeBoundSessionFixture() throws -> BoundSessionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainsongAppStateSaveRefusalTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = try WorkspaceFileSystemRootAuthority(rootURL: directory).canonicalRootURL
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try "disk A".write(to: post, atomically: true, encoding: .utf8)
        let location = try WorkspaceFileSystemRootAuthority(rootURL: root).location(relativePath: "post.md")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: "edited A", url: post, fileKind: .markdown, isDirty: true)
        let appState = AppState(shownSession: session, shouldRestoreLastOpenedFile: false)
        appState.registry.sessionCache[post] = session
        let binding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = binding
        return BoundSessionFixture(root: root, post: post, session: session, binding: binding, appState: appState)
    }
}
