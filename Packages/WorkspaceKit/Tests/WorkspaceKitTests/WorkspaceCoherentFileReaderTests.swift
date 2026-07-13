import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class WorkspaceCoherentFileReaderTests: XCTestCase {
    func testCoherentReadReportsMissingWithoutCreatingArtifacts() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("missing.md")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let outcome = await WorkspaceCoherentFileReader().readCoherentFile(at: fileURL)

        XCTAssertEqual(outcome, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".plainsong-write-") }
        )
    }

    func testReadHoldsOneAccessLeaseAcrossEveryPreflightReadAndPostflight() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("post.md")
        let source = "literal e\u{301} bytes"
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recorder = EventRecorder()
        let reader = WorkspaceCoherentFileReader { event in
            recorder.append(event)
        }

        let outcome = await reader.readCoherentFile(at: fileURL)

        guard case let .loaded(snapshot) = outcome else {
            let location = try? WorkspaceFileSystemLocation(fileURL: fileURL)
            return XCTFail(
                "Expected one coherent snapshot, got \(outcome); " +
                    "root: \(String(describing: location?.rootURL)); " +
                    "events: \(recorder.events)"
            )
        }
        XCTAssertEqual(snapshot.text, source)
        XCTAssertEqual(snapshot.exactBytes, Data(source.utf8))
        XCTAssertEqual(
            snapshot.sha256Digest,
            WorkspaceSearchContentFingerprint(text: source).sha256Digest
        )
        let events = recorder.events
        XCTAssertEqual(events.first, .accessBegan)
        XCTAssertEqual(events.filter { $0 == .accessBegan }.count, 1)
        XCTAssertEqual(events.filter { $0 == .accessEnded }.count, 1)
        XCTAssertTrue(events.contains(.preflight(0)))
        XCTAssertTrue(events.contains(.opened(0)))
        XCTAssertTrue(events.contains(.bytesRead(0)))
        XCTAssertTrue(events.contains(.postflight(0)))
        guard let postflightIndex = events.firstIndex(of: .postflight(0)),
              let accessEndedIndex = events.firstIndex(of: .accessEnded),
              let digestIndex = events.firstIndex(of: .digestChunk(0))
        else {
            return XCTFail("Expected one leased read followed by unleased digest work: \(events)")
        }
        XCTAssertLessThan(postflightIndex, accessEndedIndex)
        XCTAssertLessThan(accessEndedIndex, digestIndex)
    }

    func testSameInodeRewriteWithRestoredModificationTimeRetriesOnByteCountAndContent() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("post.md")
        let oldSource = "old-byte"
        let newSource = "new-byte-with-growth"
        let restoredDate = Date(timeIntervalSince1970: 1_700_000_000)
        try oldSource.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: restoredDate],
            ofItemAtPath: fileURL.path
        )
        let originalMetadata = try metadata(at: fileURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recorder = EventRecorder()
        let mutation = OneShotMutation { [self] in
            try rewriteInPlace(Data(newSource.utf8), at: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: restoredDate],
                ofItemAtPath: fileURL.path
            )
        }
        let reader = WorkspaceCoherentFileReader { event in
            recorder.append(event)
            if event == .bytesRead(0) {
                mutation.run()
            }
        }

        let outcome = await reader.readCoherentFile(at: fileURL)

        guard case let .loaded(snapshot) = outcome else {
            return XCTFail("Expected retried coherent snapshot, got \(outcome)")
        }
        XCTAssertEqual(snapshot.text, newSource)
        XCTAssertEqual(snapshot.metadata.identity, originalMetadata.identity)
        XCTAssertNotEqual(snapshot.metadata.byteCount, originalMetadata.byteCount)
        XCTAssertEqual(snapshot.metadata.modificationSeconds, originalMetadata.modificationSeconds)
        XCTAssertEqual(snapshot.metadata.modificationNanoseconds, originalMetadata.modificationNanoseconds)
        XCTAssertTrue(recorder.events.contains(.retry(0)))
        XCTAssertTrue(recorder.events.contains(.preflight(1)))
    }

    func testCancellationBeforeAttemptReleasesLeaseWithoutOpeningRoot() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("post.md")
        try "needle".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recorder = EventRecorder()
        let reader = WorkspaceCoherentFileReader { event in
            recorder.append(event)
            if event == .preflight(0) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let outcome = await Task { await reader.readCoherentFile(at: fileURL) }.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(recorder.events.contains(.cancelled))
        XCTAssertFalse(recorder.events.contains(.rootAnchored(0)))
        XCTAssertEqual(recorder.events.last, .accessEnded)
    }

    func testCancellationInside64KiBReadLoopClosesDescriptorAndLease() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("large.md")
        try Data(repeating: 0x61, count: 3 * 64 * 1024).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recorder = EventRecorder()
        let reader = WorkspaceCoherentFileReader { event in
            recorder.append(event)
            if event == .readChunk(0, 0) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let outcome = await Task { await reader.readCoherentFile(at: fileURL) }.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(recorder.events.contains(.opened(0)))
        XCTAssertTrue(recorder.events.contains(.readChunk(0, 0)))
        XCTAssertTrue(recorder.events.contains(.cancelled))
        XCTAssertFalse(recorder.events.contains(.bytesRead(0)))
        XCTAssertFalse(recorder.events.contains(.postflight(0)))
        XCTAssertEqual(recorder.events.last, .accessEnded)
    }

    func testCancellationDuring64KiBDigestChunksHappensAfterLeaseEnds() async throws {
        let rootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent("large.md")
        try Data(repeating: 0x61, count: 3 * 64 * 1024).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recorder = EventRecorder()
        let reader = WorkspaceCoherentFileReader { event in
            recorder.append(event)
            if event == .digestChunk(0) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let outcome = await Task { await reader.readCoherentFile(at: fileURL) }.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(recorder.events.contains(.bytesRead(0)))
        XCTAssertTrue(recorder.events.contains(.postflight(0)))
        guard let accessEndedIndex = recorder.events.firstIndex(of: .accessEnded),
              let digestIndex = recorder.events.firstIndex(of: .digestChunk(0))
        else {
            return XCTFail("Expected lease completion before digest processing: \(recorder.events)")
        }
        XCTAssertLessThan(accessEndedIndex, digestIndex)
        XCTAssertTrue(recorder.events.contains(.cancelled))
    }

    func testNoFollowReaderRejectsSymlinkAndInvalidUTF8() async throws {
        let rootURL = try makeTemporaryDirectory()
        let targetURL = rootURL.appendingPathComponent("target.md")
        let symlinkURL = rootURL.appendingPathComponent("alias.md")
        let invalidURL = rootURL.appendingPathComponent("invalid.md")
        try "sentinel".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )
        try Data([0xFF, 0xFE]).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = WorkspaceCoherentFileReader()
        let symlinkOutcome = await reader.readCoherentFile(at: symlinkURL)
        let invalidOutcome = await reader.readCoherentFile(at: invalidURL)
        XCTAssertEqual(symlinkOutcome, .symbolicLink)
        XCTAssertEqual(invalidOutcome, .invalidUTF8)
        XCTAssertEqual(
            WorkspaceNoFollowFileInspector.status(at: symlinkURL),
            .symbolicLink
        )
    }
}

private extension WorkspaceCoherentFileReaderTests {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCoherentFileReaderTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func metadata(at url: URL) throws -> WorkspaceCoherentFileMetadata {
        var fileStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }
        guard result == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return WorkspaceCoherentFileReader.metadata(from: fileStatus)
    }

    func rewriteInPlace(_ data: Data, at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }

        let written = data.withUnsafeBytes { bytes in
            Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard written == data.count, Darwin.fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkspaceCoherentFileReader.Event] = []

    var events: [WorkspaceCoherentFileReader.Event] {
        lock.withLock { storage }
    }

    func append(_ event: WorkspaceCoherentFileReader.Event) {
        lock.withLock { storage.append(event) }
    }
}

private final class OneShotMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: () throws -> Void
    private var didRun = false

    init(operation: @escaping () throws -> Void) {
        self.operation = operation
    }

    func run() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            try? operation()
        }
    }
}
