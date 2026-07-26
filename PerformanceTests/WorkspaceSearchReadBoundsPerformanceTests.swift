import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

// Probes that the production reader's *reads* are bounded, not merely its returned buffers.
//
// The admission-boundary probe asserts `diskReadByteCount`, but that instrumentation is derived
// from the same `Data` the reader returns. A reader that read an entire 4 MiB file and then
// truncated to 524,289 bytes would produce an identical number, so on its own that assertion
// cannot separate "stopped reading at the limit" from "read everything and sliced". These probes
// close that gap by observing `WorkspaceSearchDiskFileReader`'s `readChunk` events, which are
// emitted once per 64 KiB `read(2)` inside `WorkspaceAnchoredFileSystem.readAllBytes`.

/// Collects reader events from the reader's `@Sendable` handler, which is synchronous and may be
/// invoked from the read pipeline's task group.
final class ReaderEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkspaceSearchDiskFileReader.Event] = []

    func record(_ event: WorkspaceSearchDiskFileReader.Event) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [WorkspaceSearchDiskFileReader.Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// One entry per observed `read(2)` on `suffix`, in emission order.
    func reads(forPathSuffix suffix: String) -> [ObservedRead] {
        events.compactMap { event in
            guard case let .readChunk(_, chunkIndex, requested, returned, path) = event,
                  path.hasSuffix(suffix)
            else {
                return nil
            }
            return ObservedRead(index: chunkIndex, requested: requested, returned: returned)
        }
    }

    struct ObservedRead: Equatable {
        let index: Int
        let requested: Int
        let returned: Int
    }
}

extension [ReaderEventRecorder.ObservedRead] {
    var totalRequested: Int {
        reduce(0) { $0 + $1.requested }
    }

    var totalReturned: Int {
        reduce(0) { $0 + $1.returned }
    }
}

extension WorkspaceSearchPerformanceTests {
    /// `readAllBytes` reads in 64 KiB chunks and stops once it has `maximumByteCount` bytes, so a
    /// correctly bounded read of any oversized file performs exactly
    /// `ceil(524,289 / 65,536) = 9` reads — eight full chunks plus a one-byte tail. Reading the
    /// 4 MiB file in full would be 64 chunks.
    func testOversizedFileIsReadOnlyToTheInclusiveLimit() async throws {
        let fixture = try await makeAdmissionBoundaryFixture()
        defer { removeDirectory(fixture.rootURL) }

        let recorder = ReaderEventRecorder()
        let reader = WorkspaceSearchDiskFileReader { event in recorder.record(event) }
        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-read-bounds",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let service = WorkspaceSearchService(reader: reader)
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }

        let summary = try XCTUnwrap(completedSummaries(in: events).first)
        XCTAssertEqual(summary.candidateFileCount, 2)
        XCTAssertEqual(summary.searchedFileCount, 1)
        XCTAssertEqual(summary.skippedFileCount, 1)

        let oversized = recorder.reads(forPathSuffix: "oversized.md")
        let admitted = recorder.reads(forPathSuffix: "admitted.md")

        XCTAssertEqual(
            oversized.map(\.index),
            Array(0 ..< Self.boundedOversizedReadChunkCount),
            """
            the oversized sibling must be read in exactly \(Self.boundedOversizedReadChunkCount) \
            chunks; \(Self.unboundedOversizedReadChunkCount) would mean the whole file was read
            """
        )

        // Chunk counts alone are not enough: a loop that asked for a full 64 KiB buffer on the
        // final read and truncated afterwards produces these same nine indices. Assert the bytes
        // actually asked of `read(2)` and actually returned.
        XCTAssertEqual(
            oversized.totalRequested,
            Self.boundedOversizedReadByteCount,
            "the syscalls must request exactly the inclusive limit in total"
        )
        XCTAssertEqual(oversized.totalReturned, Self.boundedOversizedReadByteCount)
        XCTAssertEqual(
            oversized.last?.requested,
            1,
            "the final read must ask for the single remaining byte, not a full buffer"
        )
        XCTAssertTrue(oversized.allSatisfy { $0.requested <= Self.readChunkByteCount })
        XCTAssertLessThan(oversized.totalReturned, Self.oversizedFileByteCount)

        // The admitted file stops one chunk earlier: its ninth read returns EOF, which emits no
        // chunk event, so a correct bounded read of an exactly-at-cap file is eight chunks.
        XCTAssertEqual(admitted.map(\.index), Array(0 ..< Self.admittedFileReadChunkCount))
        XCTAssertEqual(admitted.totalRequested, Self.admittedFileByteCount)
        XCTAssertEqual(admitted.totalReturned, Self.admittedFileByteCount)

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 2,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 1,
            label: "read bounds"
        )
    }

    /// The 64 KiB ignore-file ceiling has behavior, not just a pinned constant: an oversized
    /// `.gitignore` is read only to `inclusiveLimit(65,536)` and is then rejected outright, so its
    /// rules must not take effect. Without the size rejection the ignored file would disappear
    /// from the results; without the bounded read the chunk count would exceed two.
    func testOversizedIgnoreFileIsBoundedAndItsRulesAreRejected() async throws {
        let fixture = try await makeOversizedIgnoreFixture()
        defer { removeDirectory(fixture.rootURL) }

        let recorder = ReaderEventRecorder()
        let reader = WorkspaceSearchDiskFileReader { event in recorder.record(event) }
        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-oversized-ignore",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let service = WorkspaceSearchService(reader: reader)
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }

        // The rule inside the oversized `.gitignore` names this file. Because the ignore file is
        // over the ceiling it is discarded unparsed, so the file is still searched.
        XCTAssertEqual(
            fileResults(in: events).map(\.relativePath),
            [fixture.ignoredRelativePath],
            "an over-ceiling ignore file must not be applied"
        )

        let ignoreReads = recorder.reads(forPathSuffix: ".gitignore")
        XCTAssertEqual(
            ignoreReads.map(\.index),
            Array(0 ..< Self.boundedIgnoreReadChunkCount),
            """
            the oversized .gitignore must be read in exactly \
            \(Self.boundedIgnoreReadChunkCount) chunks, not to its full \
            \(Self.oversizedIgnoreFileByteCount) bytes
            """
        )
        XCTAssertEqual(
            ignoreReads.totalRequested,
            Self.boundedIgnoreReadByteCount,
            "two chunks could still be 131,072 bytes; the requested total is what bounds it"
        )
        XCTAssertEqual(ignoreReads.totalReturned, Self.boundedIgnoreReadByteCount)
        XCTAssertEqual(ignoreReads.last?.requested, 1)
        XCTAssertLessThan(ignoreReads.totalReturned, Self.oversizedIgnoreFileByteCount)

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 1,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 0,
            label: "oversized ignore"
        )
    }

    /// Control for the probe above: the identical rule in an under-ceiling `.gitignore` *is*
    /// applied. Without this, "no results were suppressed" could equally mean the ignore rule
    /// never worked at all.
    func testUnderCeilingIgnoreFileRulesAreApplied() async throws {
        let fixture = try await makeUnderCeilingIgnoreFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-under-ceiling-ignore",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let run = try await collect(request: request)
        let summary = try XCTUnwrap(completedSummaries(in: run.events).first)

        XCTAssertTrue(
            fileResults(in: run.events).isEmpty,
            "an under-ceiling ignore file must suppress the matching file"
        )
        XCTAssertEqual(summary.ignoredFileCount, 1)
        XCTAssertEqual(summary.searchedFileCount, 0)
        XCTAssertEqual(summary.skippedFileCount, 0)

        // No candidate survives here, so the shared invariants' progress model does not apply;
        // terminal correctness is still asserted, so a `.failed` terminal or a missing completion
        // cannot pass.
        XCTAssertTrue(failures(in: run.events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: run.events), 1)
        guard let last = run.events.last, case .completed = last else {
            return XCTFail("completion must be the final event")
        }
    }
}
