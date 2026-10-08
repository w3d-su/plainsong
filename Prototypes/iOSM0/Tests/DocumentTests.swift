@testable import PlainsongIOSM0
import XCTest

final class DocumentTests: XCTestCase {
    @MainActor
    func testCleanDocumentSwitchClosesThroughAutosaveFence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let editor = SourceEditor()
        let session = DocumentSession(editor: editor, probe: Probe())
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        XCTAssertEqual(editor.textView.text, "first")
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertEqual(editor.textView.text, "second")
        XCTAssertEqual(session.document?.fileURL, second)
        if let document = session.document {
            let _: Bool = await withCheckedContinuation { c in document.close { c.resume(returning: $0) } }
        }
    }

    @MainActor
    func testRealUIDocumentRejectsExternalBytesAtWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.md")
        try Data("external".utf8).write(to: url)
        let document = SpikeDocument(fileURL: url)
        try document.load(fromContents: Data("baseline".utf8), ofType: "public.plain-text")
        let success: Bool = await withCheckedContinuation { continuation in
            document.persist("local", baseline: "baseline") { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(success)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    @MainActor
    func testRealUIDocumentSaveAndReopenExactUnicode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.md")
        try Data("baseline".utf8).write(to: url)
        let document = SpikeDocument(fileURL: url)
        let opened: Bool = await withCheckedContinuation { c in document.open { c.resume(returning: $0) } }
        XCTAssertTrue(opened)
        let source = "# 中文\n👩🏽‍💻 é"
        let saved: Bool = await withCheckedContinuation { c in
            document.persist(source, baseline: "baseline") { c.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
        document.requestAutosave = { $0(true) }
        let closed: Bool = await withCheckedContinuation { c in document.close { c.resume(returning: $0) } }
        XCTAssertTrue(closed)
        let reopened = SpikeDocument(fileURL: url)
        let ready: Bool = await withCheckedContinuation { c in reopened.open { c.resume(returning: $0) } }
        XCTAssertTrue(ready)
        XCTAssertEqual(reopened.loadedSource, source)
        reopened.requestAutosave = { $0(true) }
        let _: Bool = await withCheckedContinuation { c in reopened.close { c.resume(returning: $0) } }
    }

    func testSingleFileGrantCannotEnumerateParentOrSibling() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture.md")
        let grant = try AccessGrant(root: url, scope: .singleFile, appPrivate: true)
        XCTAssertThrowsError(try grant.listMarkdownFiles())
        grant.release()
        grant.release()
    }

    func testDirectorySkipsSymlinkAndNonMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("real.md")
        try Data("fixture".utf8).write(to: file)
        try Data().write(to: directory.appendingPathComponent("other.txt"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.md"),
            withDestinationURL: file
        )
        let grant = try AccessGrant(root: directory, scope: .directory, appPrivate: true)
        XCTAssertEqual(try grant.listMarkdownFiles().map(\.lastPathComponent), ["real.md"])
        grant.release()
        XCTAssertThrowsError(try grant.listMarkdownFiles())
    }
}
