import Foundation
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewAssetFenceTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    func testContainedReadDeliversBytes() async throws {
        let root = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let reader = handler.reader
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("read started") { reader.hasWaiter() }
        let finished = expectation(description: "delivered")
        task.onTerminal = { finished.fulfill() }
        reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(task.data, PreviewAssetTestSupport.onePixelPNG)
        XCTAssertEqual(task.finished, 1)
        XCTAssertEqual(task.failures, 0)
    }

    func testBlockedReadFromRootADoesNotDeliverIntoRootB() async throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        let handler = makeHandler(root: rootA, generation: 1)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("root A read") { handler.reader.hasWaiter() }
        _ = handler.handler.updateAuthority(PreviewAssetTestSupport.access(root: rootB, generation: 1))
        await assertNoCallback(task) {
            handler.reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        }
    }

    func testSameURLNewGrantDropsThePreviousRead() async throws {
        let root = try makeRoot()
        let grant = UUID()
        let rootToken = UUID()
        let handler = makeHandler(root: root, generation: 4, grant: grant, token: rootToken)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("grant read") { handler.reader.hasWaiter() }
        _ = handler.handler.updateAuthority(
            PreviewAssetTestSupport.access(root: root, generation: 5, grant: grant, token: rootToken)
        )
        await assertNoCallback(task) {
            handler.reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        }
    }

    func testStopDropsALateRead() async throws {
        let root = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("stopped read") { handler.reader.hasWaiter() }
        handler.handler.stop(task)
        await assertNoCallback(task) {
            handler.reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        }
    }

    func testInvalidateDropsALateRead() async throws {
        let root = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("invalidated read") { handler.reader.hasWaiter() }
        handler.handler.invalidateReads()
        await assertNoCallback(task) {
            handler.reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        }
    }

    func testOversizedBytesAfterSmallMetadataAreRejected() async throws {
        let root = try makeRoot()
        let fileURL = root.appendingPathComponent("pixel.png")
        try Data([0x89]).write(to: fileURL)
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("metadata passed") { handler.reader.hasWaiter() }
        let failed = expectation(description: "too large")
        task.onTerminal = { failed.fulfill() }
        handler.reader.resumeFirst(bytes: Data(count: Int(AssetURLPolicy.maxAssetBytes) + 1), coordinatedURL: fileURL)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(task.finished, 0)
        XCTAssertEqual(task.failures, 1)
        XCTAssertEqual(handler.reader.readCount, 1)
    }

    func testProviderBytesOutsideTheRootAreRejected() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler)
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("outside read") { handler.reader.hasWaiter() }
        let failed = expectation(description: "outside")
        task.onTerminal = { failed.fulfill() }
        handler.reader.resumeFirst(
            bytes: PreviewAssetTestSupport.onePixelPNG,
            coordinatedURL: outside.appendingPathComponent("secret.png")
        )
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(task.finished, 0)
        XCTAssertEqual(task.failures, 1)
    }

    func testSymlinkRetargetDuringReadIsRejected() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        let inside = root.appendingPathComponent("inside.png")
        let link = root.appendingPathComponent("link.png")
        try PreviewAssetTestSupport.onePixelPNG.write(to: inside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler, path: "link.png")
        handler.handler.start(task)
        await PreviewAssetTestSupport.waitUntil("symlink read") { handler.reader.hasWaiter() }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside.appendingPathComponent("secret.png")
        )
        let failed = expectation(description: "symlink")
        task.onTerminal = { failed.fulfill() }
        handler.reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG, coordinatedURL: link)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(task.finished, 0)
    }

    func testMissingAndWrongTokensDoNotRead() async throws {
        let root = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let missing = RecordingSchemeTask(url: URL(string: "asset://pixel.png"))
        handler.handler.start(missing)
        let wrong = RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: "not-the-token"))
        handler.handler.start(wrong)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(handler.reader.readCount, 0)
        XCTAssertEqual(missing.failures, 1)
        XCTAssertEqual(wrong.failures, 1)
        XCTAssertTrue(missing.data.isEmpty)
        XCTAssertTrue(wrong.data.isEmpty)
    }

    func testSVGIsRejectedBeforeTheReader() async throws {
        let root = try makeRoot()
        let handler = makeHandler(root: root, generation: 1)
        let task = makeTask(handler, path: "vector.svg")
        handler.handler.start(task)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(handler.reader.readCount, 0)
        XCTAssertEqual(task.failures, 1)
        XCTAssertTrue(task.data.isEmpty)
    }

    func testPrefixSiblingFileURLIsOutsideTheRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/plainsong-site", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/tmp/plainsong-site-evil/pixel.png")
        XCTAssertThrowsError(try AssetContainment.fileURL(sibling, isContainedIn: root)) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }

    func testNilGrantDoesNotAuthorizeTheFileParent() {
        let file = URL(fileURLWithPath: "/tmp/site/content/post.md")
        let context = PreviewController.grantedAssetContext(fileURL: file, access: nil)
        XCTAssertNil(context.allowedRoot)
        XCTAssertNil(context.baseDir)
        let granted = PreviewAssetTestSupport.access(
            root: URL(fileURLWithPath: "/tmp/site", isDirectory: true),
            generation: 3
        )
        let inside = PreviewController.grantedAssetContext(fileURL: file, access: granted)
        XCTAssertEqual(inside.allowedRoot, granted.allowedRoot)
        XCTAssertEqual(inside.baseDir, "content")
    }

    private func assertNoCallback(_ task: RecordingSchemeTask, release: () -> Void) async {
        let callback = expectation(description: "late callback")
        callback.isInverted = true
        task.onTerminal = { callback.fulfill() }
        release()
        await fulfillment(of: [callback], timeout: 0.5)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertEqual(task.responseCount, 0)
        XCTAssertEqual(task.finished, 0)
        XCTAssertEqual(task.failures, 0)
    }

    private func makeRoot() throws -> URL {
        let root = try PreviewAssetTestSupport.directory()
        directories.append(root)
        return root
    }

    private func makeHandler(
        root: URL,
        generation: UInt64,
        grant: UUID = UUID(),
        token: UUID = UUID()
    ) -> (handler: AssetURLSchemeHandler, reader: GatePreviewAssetReader, plainsongToken: String) {
        let handler = AssetURLSchemeHandler()
        let reader = GatePreviewAssetReader()
        handler.installReader(reader)
        let plainsongToken = handler.updateAuthority(
            PreviewAssetTestSupport.access(root: root, generation: generation, grant: grant, token: token)
        ).token
        return (handler, reader, plainsongToken)
    }

    private func makeTask(
        _ handler: (handler: AssetURLSchemeHandler, reader: GatePreviewAssetReader, plainsongToken: String),
        path: String = "pixel.png"
    ) -> RecordingSchemeTask {
        RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: handler.plainsongToken, path: path))
    }
}
