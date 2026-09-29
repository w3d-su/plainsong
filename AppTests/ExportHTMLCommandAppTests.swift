import AppKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// Export PR F Phase A: the production File › Export as HTML… path, with the save panel
/// replaced by the injected destination seam. Each test runs the real snapshot, dedicated
/// offscreen `PreviewController`, `exportHTML`, and one-shot writer inside the hosted app.
@MainActor
final class ExportHTMLCommandAppTests: XCTestCase {
    func testExportWritesAStandaloneHTMLFileToANewDestination() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("post.html")
        let recorder = fixture.record(returning: [destination])
        let documentBefore = DocumentState(fixture.session)
        let recentsBefore = fixture.appState.recentItemURLs

        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

        guard case let .written(.committed(commit)) = try XCTUnwrap(recorder.results.first?.result) else {
            return XCTFail("Expected a committed export, got \(recorder.results)")
        }
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(commit.selectedURL, destination)
        XCTAssertEqual(
            recorder.requests,
            [ExportHTMLDestinationRequest(defaultFileName: "post.html", directoryURL: fixture.root)]
        )
        let html = try String(contentsOf: destination, encoding: .utf8)
        assertStandalone(html, fixture: fixture)
        XCTAssertTrue(html.contains("Export Command Heading"))
        XCTAssertTrue(html.contains("data:image/png;base64,"), "the workspace image must be embedded")
        XCTAssertEqual(try operationSiblings(in: fixture.exportsDirectory), [])
        XCTAssertEqual(DocumentState(fixture.session), documentBefore)
        XCTAssertTrue(fixture.appState.currentDocument === fixture.session)
        XCTAssertEqual(fixture.appState.recentItemURLs, recentsBefore)
        XCTAssertEqual(fixture.appState.presentedError?.title, "Exported as HTML")
        XCTAssertNil(fixture.appState.exportHTMLOperations.activeOperationID)
        XCTAssertEqual(recorder.controllers.count, 1)
        XCTAssertTrue(try XCTUnwrap(recorder.controllers.first).isInvalidated)
    }

    func testConfirmedOverwriteReplacesTheExistingHTMLFile() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("existing.html")
        try Data("<p>previous export</p>".utf8).write(to: destination)
        let recorder = fixture.record(returning: [destination])

        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

        guard case .written(.committed) = try XCTUnwrap(recorder.results.first?.result) else {
            return XCTFail("Expected a committed overwrite, got \(recorder.results)")
        }
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(html.contains("previous export"))
        assertStandalone(html, fixture: fixture)
        XCTAssertEqual(try operationSiblings(in: fixture.exportsDirectory), [])
    }

    func testDocumentEditWhileThePanelIsOpenPreventsTheWrite() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("edited.html")
        let recorder = fixture.record(returning: [destination]) {
            fixture.session.replaceText("# Edited after invocation\n")
        }

        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

        XCTAssertEqual(recorder.results.map(\.result), [.stopped(.documentChanged)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        XCTAssertEqual(try operationSiblings(in: fixture.exportsDirectory), [])
        XCTAssertTrue(try XCTUnwrap(recorder.controllers.first).isInvalidated)
        XCTAssertEqual(fixture.session.text, "# Edited after invocation\n")
    }

    func testSupersedingExportPreventsTheOlderWrite() async throws {
        let fixture = try makeFixture()
        let olderDestination = fixture.exportsDirectory.appendingPathComponent("older.html")
        let newerDestination = fixture.exportsDirectory.appendingPathComponent("newer.html")
        var newerTask: Task<Void, Never>?
        let recorder = fixture.record(returning: [olderDestination, newerDestination]) {
            if newerTask == nil {
                newerTask = fixture.appState.exportCurrentDocumentAsHTML()
            }
        }

        let olderTask = try XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML())
        await olderTask.value
        try await XCTUnwrap(newerTask).value

        XCTAssertEqual(recorder.results.count, 2)
        let results = Dictionary(uniqueKeysWithValues: recorder.results.map { ($0.operationID, $0.result) })
        XCTAssertEqual(results[1], .stopped(.superseded))
        guard case let .written(.committed(commit)) = results[2] else {
            return XCTFail("Expected the newer export to commit, got \(recorder.results)")
        }
        XCTAssertEqual(commit.selectedURL, newerDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderDestination.path(percentEncoded: false)))
        XCTAssertEqual(try operationSiblings(in: fixture.exportsDirectory), [])
        XCTAssertEqual(recorder.controllers.count, 2)
        XCTAssertTrue(recorder.controllers.allSatisfy(\.isInvalidated))
    }

    func testWorkspaceSwitchWhileThePanelIsOpenPreventsTheWrite() async throws {
        let fixture = try makeFixture()
        let destination = fixture.exportsDirectory.appendingPathComponent("workspace.html")
        let recorder = fixture.record(returning: [destination]) {
            fixture.appState.workspaceRootURL = fixture.exportsDirectory
        }

        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

        XCTAssertEqual(recorder.results.map(\.result), [.stopped(.workspaceChanged)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    func testMDXSyntaxErrorFailsWithoutWriting() async throws {
        let fixture = try makeFixture(name: "broken.mdx", text: "# Broken\n\n<Component unclosed\n")
        let destination = fixture.exportsDirectory.appendingPathComponent("broken.html")
        let recorder = fixture.record(returning: [destination])

        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsHTML()).value

        XCTAssertEqual(recorder.results.map(\.result), [.stopped(.renderFailed(reason: "mdx-stale-or-error"))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        XCTAssertEqual(fixture.appState.presentedError?.title, "Could Not Export as HTML")
    }

    func testResultTextNamesTheExactFailureAndEveryIndeterminatePath() throws {
        let selected = URL(fileURLWithPath: "/Volumes/Smoke/Desktop/post.html")
        let staging = URL(fileURLWithPath: "/Volumes/Smoke/Desktop/.plainsong-tmp-1")
        let cleanup = URL(fileURLWithPath: "/Volumes/Smoke/Desktop/.plainsong-cleanup-2")

        XCTAssertEqual(
            ExportHTMLResultMessage.notice(for: .written(.notCommitted(.stagingNotPermitted(code: 1))))?.message,
            "Nothing was written. Reason: ExportArtifactFailure.stagingNotPermitted(code: 1)."
        )
        XCTAssertEqual(
            ExportHTMLResultMessage.notice(for: .stopped(.destinationRefused(.parentAuthorityUnavailable)))?.message,
            "The destination was refused: ExportArtifactFailure.parentAuthorityUnavailable. Nothing was written."
        )
        let indeterminate = try XCTUnwrap(ExportHTMLResultMessage.notice(for: .written(.indeterminate(
            ExportArtifactIndeterminateWrite(
                reason: .cleanupFailed,
                selectedURL: selected,
                destinationState: .holdsWriterBytes,
                residue: .retained(cleanup, holding: .displacedOriginal),
                stagingURL: staging
            )
        ))))
        XCTAssertEqual(indeterminate.title, "HTML Export Could Not Be Confirmed")
        XCTAssertEqual(
            indeterminate.message,
            "The export to /Volumes/Smoke/Desktop/post.html could not be confirmed " +
                "(WorkspaceAnchoredFileSystemError.cleanupFailed). " +
                "The selected file holds the exported HTML, but cleanup was not proven. " +
                "Your original file is now at /Volumes/Smoke/Desktop/.plainsong-cleanup-2. " +
                "Operation entry to inspect: /Volumes/Smoke/Desktop/.plainsong-tmp-1."
        )
        XCTAssertNil(ExportHTMLResultMessage.notice(for: .stopped(.cancelled)))
        XCTAssertNil(ExportHTMLResultMessage.notice(for: .stopped(.superseded)))
    }

    func testUntitledDocumentIsRefusedBeforeAnyPanel() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        var chooserCalls = 0
        appState.exportHTMLOperations.destinationChooser = { _ in
            chooserCalls += 1
            return nil
        }

        XCTAssertFalse(appState.canExportCurrentDocumentAsHTML)
        XCTAssertNil(appState.exportCurrentDocumentAsHTML())
        XCTAssertEqual(chooserCalls, 0)
        XCTAssertEqual(
            appState.presentedError?.message,
            "Save the document before exporting it as HTML. Nothing was written."
        )
    }
}

// MARK: - Fixtures

extension ExportHTMLCommandAppTests {
    struct DocumentState: Equatable {
        let text: String
        let version: Int
        let isDirty: Bool
        let fileURL: URL?

        @MainActor
        init(_ session: DocumentSession) {
            text = session.text
            version = session.version
            isDirty = session.isDirty
            fileURL = session.fileURL
        }
    }

    @MainActor
    final class Recorder {
        var requests: [ExportHTMLDestinationRequest] = []
        var results: [(operationID: UInt64, result: ExportHTMLOperationResult)] = []
        var controllers: [PreviewController] = []
    }

    struct Fixture {
        let root: URL
        let exportsDirectory: URL
        let appState: AppState
        let session: DocumentSession

        /// Answers each panel request with the next URL, after running `whilePanelIsOpen`.
        @MainActor
        func record(
            returning destinations: [URL],
            whilePanelIsOpen: @escaping @MainActor () -> Void = {}
        ) -> Recorder {
            let recorder = Recorder()
            let appState = appState
            appState.exportHTMLOperations.destinationChooser = { request in
                let index = recorder.requests.count
                recorder.requests.append(request)
                if let controller = appState.exportHTMLOperations.offscreenController {
                    recorder.controllers.append(controller)
                }
                whilePanelIsOpen()
                return index < destinations.count ? destinations[index] : nil
            }
            appState.exportHTMLOperations.didFinishOperation = { operationID, result in
                recorder.results.append((operationID, result))
            }
            return recorder
        }
    }

    /// A workspace whose current document is a clean anchored `name` session beside an
    /// `assets/pixel.png` image, plus an `exports/` destination folder.
    func makeFixture(
        name: String = "post.md",
        text: String = "# Export Command Heading\n\n![pixel](assets/pixel.png)\n\n- [x] done\n"
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportHTMLCommandAppTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // The writer refuses symlinked parent paths, so use the canonical container path.
        let root = try WorkspaceFileSystemRootAuthority(rootURL: directory).canonicalRootURL
        let exportsDirectory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try pngData().write(to: root.appendingPathComponent("assets/pixel.png"))
        let documentURL = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: documentURL)

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: name)
        let read = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: text, url: documentURL)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[documentURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: read.metadata.identity,
                sha256Digest: read.sha256Digest
            )
        addTeardownBlock { @MainActor in
            appState.exportHTMLOperations.activeTask?.cancel()
        }
        return Fixture(root: root, exportsDirectory: exportsDirectory, appState: appState, session: session)
    }

    func assertStandalone(
        _ html: String,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), file: file, line: line)
        XCTAssertTrue(html.contains("Content-Security-Policy"), file: file, line: line)
        XCTAssertTrue(html.contains("script-src 'none'"), file: file, line: line)
        XCTAssertFalse(html.contains("<script"), file: file, line: line)
        XCTAssertFalse(html.contains("asset://"), file: file, line: line)
        XCTAssertFalse(html.contains("file:"), file: file, line: line)
        XCTAssertFalse(html.contains(fixture.root.path(percentEncoded: false)), file: file, line: line)
    }

    func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.setColor(.systemTeal, atX: 0, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func operationSiblings(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix(".plainsong-") }
    }
}
