@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR B2 fixture: one `AppState` whose shared window shows `first`, plus a second,
/// connected `WindowState` that is the only owner of `second`. `second` is in no warm cache,
/// retirement, editor binding, or recovery: only window 2's document puts it in an inventory.
@MainActor
struct SecondWindowRegistryFixture {
    let root: URL
    let authority: WorkspaceFileSystemRootAuthority
    let appState: AppState
    let secondWindow: WindowState
    let firstURL: URL
    let secondURL: URL
    let firstLocation: WorkspaceFileSystemLocation
    let secondLocation: WorkspaceFileSystemLocation
    let first: DocumentSession
    let second: DocumentSession
    /// Bound like `second`, owned by nothing else; `hideSecond()` shows it in window 2.
    let third: DocumentSession
    let secondIdentity: WorkspaceFileSystemIdentity

    static func make(testCase: XCTestCase) throws -> SecondWindowRegistryFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateRegistryAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = try WorkspaceFileSystemRootAuthority(rootURL: directory).canonicalRootURL
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try Data("first on disk".utf8).write(to: firstURL)
        try Data("second on disk".utf8).write(to: secondURL)
        let thirdURL = root.appendingPathComponent("third.md")
        try Data("third on disk".utf8).write(to: thirdURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let firstLocation = try authority.location(relativePath: "first.md")
        let secondLocation = try authority.location(relativePath: "second.md")
        let thirdLocation = try authority.location(relativePath: "third.md")
        let firstRead = try MarkdownFileStore().loadResult(at: firstLocation)
        let secondRead = try MarkdownFileStore().loadResult(at: secondLocation)
        let thirdRead = try MarkdownFileStore().loadResult(at: thirdLocation)
        let first = DocumentSession(text: "first on disk", url: firstURL, fileKind: .markdown)
        let second = DocumentSession(text: "second on disk", url: secondURL, fileKind: .markdown)
        let third = DocumentSession(text: "third on disk", url: thirdURL, fileKind: .markdown)
        let appState = AppState(shownSession: first, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.registry.sessionCache[firstURL] = first
        for (session, location, read) in [
            (first, firstLocation, firstRead), (second, secondLocation, secondRead), (third, thirdLocation, thirdRead),
        ] {
            appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: read.metadata.identity,
                sha256Digest: read.sha256Digest
            )
        }

        let secondWindow = WindowState(
            shownSession: DocumentSession(),
            layoutMode: .sourceOnly,
            wysiwygFallbackMessage: nil,
            replaceAuthority: appState.registry.replaceAuthority
        )
        // Connected before it receives any input (`UnwiredContainerHook`).
        appState.connect(secondWindow)
        secondWindow.shownSession = second
        precondition(!appState.registry.isWarmSession(second))
        return SecondWindowRegistryFixture(
            root: root,
            authority: authority,
            appState: appState,
            secondWindow: secondWindow,
            firstURL: firstURL,
            secondURL: secondURL,
            firstLocation: firstLocation,
            secondLocation: secondLocation,
            first: first,
            second: second,
            third: third,
            secondIdentity: secondRead.metadata.identity
        )
    }

    /// Takes `second` off window 2 by showing `third` there, so no inventory lists `second`.
    /// (An untitled document with no ownership record would make Save Copy fail closed.)
    func hideSecond() {
        secondWindow.shownSession = third
    }

    func text(at url: URL) throws -> String {
        try XCTUnwrap(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    /// Switches the shared window to a dirty session whose file went missing, the shape
    /// Save Copy (`saveDetachedCurrentDocument(to:)`) acts on.
    func showDetachedSessionInSharedWindow() throws -> DocumentSession {
        let missingURL = root.appendingPathComponent("missing.md")
        try Data("missing on disk".utf8).write(to: missingURL)
        let location = try authority.location(relativePath: "missing.md")
        let read = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: "unsaved missing", url: missingURL, fileKind: .markdown, isDirty: true)
        appState.registry.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: read.metadata.identity,
            sha256Digest: read.sha256Digest
        )
        appState.shownSession = session
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        return session
    }
}
