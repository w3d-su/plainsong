import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WorkspaceKit
import XCTest

/// Review High #25: the thumbnail cache was keyed without the workspace root, the read and
/// decode ran on the provider actor, and ImageIO reopened the path after the containment check.
final class WorkspaceImageThumbnailIsolationTests: XCTestCase {
    func testSameRelativePathAndMtimeInTwoWorkspacesDoNotShareACacheEntry() async throws {
        let firstRoot = try makeWorkspace()
        let secondRoot = try makeWorkspace()
        let modificationDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try writePNG(size: 40, to: firstRoot.appendingPathComponent("cover.png"), modified: modificationDate)
        try writePNG(size: 80, to: secondRoot.appendingPathComponent("cover.png"), modified: modificationDate)

        let provider = WorkspaceImageThumbnailProvider()
        let first = await provider.load(
            rootURL: firstRoot,
            documentDirectoryRelativePath: "",
            source: "cover.png",
            hasDirectoryScope: true
        )
        let second = await provider.load(
            rootURL: secondRoot,
            documentDirectoryRelativePath: "",
            source: "cover.png",
            hasDirectoryScope: true
        )

        XCTAssertEqual(first.readyThumbnail?.pixelWidth, 40)
        XCTAssertEqual(second.readyThumbnail?.pixelWidth, 80)
        let stats = await provider.cacheStats()
        XCTAssertEqual(stats.misses, 2)
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.entryCount, 2)
    }

    func testProviderActorAnswersWhileADecodeIsRunning() async throws {
        let root = try makeWorkspace()
        try writePNG(size: 40, to: root.appendingPathComponent("slow.png"))

        let decodeStarted = DispatchSemaphore(value: 0)
        let releaseDecode = DispatchSemaphore(value: 0)
        let decodeWasReleasedInTime = LockedFlag()
        var hooks = WorkspaceImageThumbnailProvider.Hooks()
        hooks.decode = { data, maxPixelSize in
            decodeStarted.signal()
            if releaseDecode.wait(timeout: .now() + 10) == .success {
                decodeWasReleasedInTime.set()
            }
            return try WorkspaceImageThumbnailDecoder.decodePNGThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
        let provider = WorkspaceImageThumbnailProvider(hooks: hooks)

        let load = Task {
            await provider.load(
                rootURL: root,
                documentDirectoryRelativePath: "",
                source: "slow.png",
                hasDirectoryScope: true
            )
        }
        await waitOffCooperativePool(for: decodeStarted)

        // With the decode on the actor this call could not return until the decode timed out.
        let stats = await provider.cacheStats()
        releaseDecode.signal()

        XCTAssertEqual(stats.misses, 1)
        let outcome = await load.value
        XCTAssertNotNil(outcome.readyThumbnail)
        XCTAssertTrue(decodeWasReleasedInTime.value)
    }

    func testSourceReadsRunOneAtATime() async throws {
        let root = try makeWorkspace()
        let names = (0 ..< 6).map { "photo\($0).png" }
        for name in names {
            try writePNG(size: 40, to: root.appendingPathComponent(name))
        }
        let overlap = OverlapCounter()
        var hooks = WorkspaceImageThumbnailProvider.Hooks()
        hooks.willReadSource = {
            overlap.enter()
            usleep(20000)
            overlap.leave()
        }
        let provider = WorkspaceImageThumbnailProvider(hooks: hooks)

        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    let outcome = await provider.load(
                        rootURL: root,
                        documentDirectoryRelativePath: "",
                        source: name,
                        hasDirectoryScope: true
                    )
                    XCTAssertNotNil(outcome.readyThumbnail)
                }
            }
        }

        XCTAssertEqual(overlap.maximum, 1)
    }

    func testEntrySwappedForAnEscapingSymlinkAfterContainmentIsNotDecoded() async throws {
        let root = try makeWorkspace()
        let outside = try makeWorkspace()
        let inside = root.appendingPathComponent("photo.png")
        let secret = outside.appendingPathComponent("secret.png")
        try writePNG(size: 40, to: inside)
        try writePNG(size: 80, to: secret)

        var hooks = WorkspaceImageThumbnailProvider.Hooks()
        hooks.willReadSource = {
            try? FileManager.default.removeItem(at: inside)
            try? FileManager.default.createSymbolicLink(at: inside, withDestinationURL: secret)
        }
        let provider = WorkspaceImageThumbnailProvider(hooks: hooks)

        let outcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "photo.png",
            hasDirectoryScope: true
        )

        XCTAssertEqual(outcome, .failed(.unreadableFile))
        let stats = await provider.cacheStats()
        XCTAssertEqual(stats.entryCount, 0)
    }
}

private final class OverlapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func enter() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

private extension WorkspaceImageThumbnailOutcome {
    var readyThumbnail: WorkspaceImageThumbnail? {
        if case let .ready(thumbnail) = self {
            return thumbnail
        }
        return nil
    }
}

private extension WorkspaceImageThumbnailIsolationTests {
    func waitOffCooperativePool(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                _ = semaphore.wait(timeout: .now() + 10)
                continuation.resume()
            }
        }
    }

    func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-thumb-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func writePNG(size: Int, to url: URL, modified: Date? = nil) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}
