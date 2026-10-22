import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

@MainActor
final class IOSImageInsertionPathTests: XCTestCase {
    func testSmartPasteRepresentsSpecialFilenames() async throws {
        let paths = [
            "assets/my photo.png",
            "assets/My Photo (final).png",
            "assets/圖片.png",
            "assets/a#b.png",
            "assets/q?u.png",
            "assets/a<b>.png",
        ]
        for path in paths {
            let harness = ImageInsertionHarness()
            harness.writer.relativePath = path
            let context = try harness.capture()
            _ = await assertInserted(harness.insert(context))
            let edit = try XCTUnwrap(harness.editor.submitted.first)
            XCTAssertEqual(edit.result.replacementString, SmartPaste.imageInsertion(relativePath: path))
            XCTAssertFalse(edit.result.replacementString.contains("file:"))
            XCTAssertFalse(edit.result.replacementString.contains("/Elsewhere"))
        }
    }

    func testWriterDedupedPathIsUsedVerbatim() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.relativePath = "assets/photo-2.png"
        harness.writer.rootRelativePath = "notes/assets/photo-2.png"
        let context = try harness.capture()
        _ = await assertInserted(harness.insert(context, filename: "from-photos.png"))
        let edit = try XCTUnwrap(harness.editor.submitted.first)
        XCTAssertEqual(edit.result.replacementString, "![](assets/photo-2.png)")
        XCTAssertFalse(edit.result.replacementString.contains("photo.png"))
        XCTAssertFalse(edit.result.replacementString.contains("notes/"))
        XCTAssertFalse(edit.result.replacementString.contains("from-photos"))
        let request = try XCTUnwrap(harness.writer.stagedRequests.first)
        XCTAssertEqual(request.preferredFilename, "from-photos.png")
        XCTAssertNotEqual(request.preferredFilename, harness.writer.relativePath)
    }

    func testIllegalWriterPathsAreNotInserted() async throws {
        let paths = [
            "",
            "../x.png",
            "/tmp/x.png",
            "file:///tmp/picked.png",
            "assets/../../x.png",
            "assets//x.png",
            "assets/./x.png",
            "assets\\x.png",
        ]
        for path in paths {
            let harness = ImageInsertionHarness()
            harness.writer.relativePath = path
            let context = try harness.capture()
            await assertFailed(harness.insert(context), .invalidPath)
            harness.assertSourceUntouched()
            XCTAssertEqual(harness.writer.rollbackCount, 1)
            XCTAssertEqual(harness.writer.commitCount, 0)
            XCTAssertFalse(harness.probe.events.contains("apply"))
        }
    }

    func testUTF16CaretStaysOnTheCapturedSelection() async throws {
        let text = "a😀"
        let selection = NSRange(location: (text as NSString).length, length: 0)
        XCTAssertEqual(selection.location, 3)
        let harness = ImageInsertionHarness(text: text, selection: selection)
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        harness.editor.selection = NSRange(location: 0, length: 0)
        harness.writer.stageRelease.signal()
        _ = await assertInserted(task.value)
        let edit = try XCTUnwrap(harness.editor.submitted.first)
        XCTAssertEqual(edit.result.replacementRange, selection)
        let markdown = SmartPaste.imageInsertion(relativePath: "assets/photo-2.png")
        XCTAssertEqual(edit.result.newSelection.location, selection.location + (markdown as NSString).length)
        XCTAssertEqual(edit.result.newSelection.length, 0)
    }

    func testPickedFileBytesAreNotTheMarkdownPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("from-photos.png")
        try ImageBytes.png.write(to: url)
        let loaded = await IOSImagePickedFileBytes.load(url: url)
        guard case let .success(payload) = loaded else {
            return XCTFail("expected picked bytes, got \(loaded)")
        }
        XCTAssertEqual(payload.bytes, ImageBytes.png)
        XCTAssertEqual(payload.preferredFilename, "from-photos.png")
        XCTAssertEqual(payload.contentType, "image/png")

        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        _ = await assertInserted(harness.insert(
            context,
            bytes: payload.bytes,
            contentType: payload.contentType,
            filename: payload.preferredFilename
        ))
        let markdown = try XCTUnwrap(harness.editor.submitted.first).result.replacementString
        XCTAssertEqual(markdown, "![](assets/photo-2.png)")
        XCTAssertFalse(markdown.contains(url.path))
        XCTAssertFalse(markdown.contains(directory.path))

        let oversized = directory.appendingPathComponent("big.png")
        try ImageBytes.png(count: ImageBytes.limit + 1).write(to: oversized)
        let rejected = await IOSImagePickedFileBytes.load(url: oversized)
        guard case .failure(.tooLarge) = rejected else {
            return XCTFail("expected too large, got \(rejected)")
        }
    }
}
