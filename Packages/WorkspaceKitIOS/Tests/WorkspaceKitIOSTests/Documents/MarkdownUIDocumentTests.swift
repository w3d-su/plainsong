import Foundation
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class MarkdownUIDocumentTests: XCTestCase {
    func testContentsForTypeReturnsTheInstalledSnapshotOnly() throws {
        let url = temporaryFile("Snapshot.md")
        let document = MarkdownUIDocument(fileURL: url)
        XCTAssertThrowsError(try document.contents(forType: "public.plain-text"))
        var live = Data("live editor buffer".utf8)
        document.installSnapshot(Data("frozen snapshot 繁中".utf8))
        live.append(Data(" mutated".utf8))
        let contents = try XCTUnwrap(try document.contents(forType: "public.plain-text") as? Data)
        XCTAssertEqual(contents, Data("frozen snapshot 繁中".utf8))
        XCTAssertNotEqual(contents, live)
        document.clearSnapshot()
        XCTAssertThrowsError(try document.contents(forType: "public.plain-text"))
        _ = live
    }

    func testLoadRejectsBytesThatDoNotRoundTrip() throws {
        let document = MarkdownUIDocument(fileURL: temporaryFile("Bad.md"))
        XCTAssertThrowsError(try document.load(fromContents: Data([0xFF, 0xFE, 0x00]), ofType: nil))
        try document.load(fromContents: Data("exact".utf8), ofType: "public.plain-text")
        XCTAssertEqual(document.loadedData(), Data("exact".utf8))
    }

    func testCreateDoesNotOverwriteExistingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-uidoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Note.md")
        let original = Data("original bytes".utf8)
        try original.write(to: url)
        let adapter = UIDocumentFileAdapter(fileURL: url)
        do {
            try await adapter.create(snapshot: Data("replacement".utf8))
            XCTFail("create must refuse an existing file")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.alreadyExists))
        }
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, original)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripPreservesUTF8() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-uidoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Note.md")
        let text = Data("草稿 繁中 👩🏽‍💻\n".utf8)
        let writer = UIDocumentFileAdapter(fileURL: url)
        try await writer.create(snapshot: text)
        let opened = try await UIDocumentFileAdapter(fileURL: url).open()
        XCTAssertEqual(opened.data, text)
        let replacement = Data("second".utf8)
        let saved = expectation(description: "saved")
        writer.save(snapshot: replacement, operationID: UUID()) { disposition in
            XCTAssertEqual(disposition, .stored)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 5)
        let reread = try Data(contentsOf: url)
        XCTAssertEqual(reread, replacement)
        try? FileManager.default.removeItem(at: directory)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }
}
