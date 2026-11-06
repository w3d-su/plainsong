import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// The volume check runs before anything is staged. Real exFAT, FAT32, and Mac OS Extended
/// volumes cannot run in CI, so their measured capabilities are injected here (the decision
/// record has the disk-image measurements); the real-volume test reads the APFS test volume.
extension WorkspaceAnchoredFileSystemTests {
    func testVolumeWithoutExclusiveRenameRefusesEverySaveBeforeStaging() throws {
        // exFAT and FAT32 report neither rename. Swap alone is not enough: cleanup moves an
        // artifact with `RENAME_EXCL`.
        for swapRename in [false, true] {
            for originalText in ["original", nil] {
                let fixture = try makeWriteFixture(originalText: originalText)
                defer { try? FileManager.default.removeItem(at: fixture.parent) }
                let events = VolumeCheckEventRecorder()
                let hooks = volumeHooks(
                    VolumeWriteCapabilities(isReadOnly: false, exclusiveRename: false, swapRename: swapRename),
                    events: events
                )

                let outcome = write(to: fixture, expecting: expectation(for: fixture), hooks: hooks)

                let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unsupportedVolume))
                XCTAssertEqual(result.artifactState, .none)
                try assertNothingStaged(fixture, originalText: originalText, events: events)
            }
        }
    }

    func testVolumeWithoutSwapRenameRefusesReplacementButStillCreatesMissingFile() throws {
        // Mac OS Extended reports exclusive renaming only.
        let capabilities = VolumeWriteCapabilities(isReadOnly: false, exclusiveRename: true, swapRename: false)
        let existing = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: existing.parent) }
        let events = VolumeCheckEventRecorder()

        let refused = write(
            to: existing,
            expecting: expectation(for: existing),
            hooks: volumeHooks(capabilities, events: events)
        )

        let result = try XCTUnwrap(requireNotCommitted(refused, reason: .unsupportedVolume))
        XCTAssertEqual(result.artifactState, .none)
        try assertNothingStaged(existing, originalText: "original", events: events)

        let missing = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: missing.parent) }
        let created = write(
            to: missing,
            expecting: .missing,
            hooks: volumeHooks(capabilities, events: VolumeCheckEventRecorder())
        )

        XCTAssertNotNil(requireDurable(created))
        XCTAssertEqual(try writeText(at: missing.destination), "replacement bytes")
        try assertNoWriteArtifacts(for: missing)
    }

    func testReadOnlyVolumeRefusesBeforeStaging() throws {
        for originalText in ["original", nil] {
            let fixture = try makeWriteFixture(originalText: originalText)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let events = VolumeCheckEventRecorder()
            let hooks = volumeHooks(
                VolumeWriteCapabilities(isReadOnly: true, exclusiveRename: true, swapRename: true),
                events: events
            )

            let outcome = write(to: fixture, expecting: expectation(for: fixture), hooks: hooks)

            let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .readOnlyVolume))
            XCTAssertEqual(result.artifactState, .none)
            try assertNothingStaged(fixture, originalText: originalText, events: events)
        }
    }

    func testUnansweredVolumeCapabilitiesRefuseBeforeStaging() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let events = VolumeCheckEventRecorder()
        let hooks = WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: events.record,
            volumeWriteCapabilities: { _ in nil }
        )

        let outcome = write(to: fixture, expecting: expectation(for: fixture), hooks: hooks)

        let result = try XCTUnwrap(requireNotCommitted(outcome, reason: .unsupportedVolume))
        XCTAssertEqual(result.artifactState, .none)
        try assertNothingStaged(fixture, originalText: "original", events: events)
    }

    /// The check asks about the destination parent, and only after the target expectation:
    /// an externally replaced document still reports `changedIdentity`, which the App treats as
    /// an external change rather than a volume problem.
    func testVolumeCheckReadsTheDestinationParentAfterTheTargetExpectation() throws {
        let fixture = try makeWriteFixture(relativePath: "drafts/post.md")
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let queried = VolumeCheckDescriptorRecorder()
        let refusing = WorkspaceAnchoredFileSystem.Hooks(volumeWriteCapabilities: { descriptor in
            queried.record(descriptor)
            return nil
        })

        let stale = write(
            to: fixture,
            expecting: .existing(WorkspaceFileSystemIdentity(device: originalIdentity.device, inode: 1)),
            hooks: refusing
        )

        XCTAssertNotNil(requireNotCommitted(stale, reason: .changedIdentity))
        XCTAssertTrue(queried.identities.isEmpty, "a failed expectation is reported before the volume check")

        _ = write(to: fixture, expecting: .existing(originalIdentity), hooks: refusing)

        let parentIdentity = try writeFileIdentity(at: fixture.destination.deletingLastPathComponent())
        XCTAssertEqual(queried.identities, [parentIdentity])
    }

    func testRealVolumeReportsWritableWithBothRenamesOnTheTestVolume() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("not-the-volume-root", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)

        // A folder grant opens the parent for reading; a file-only grant may only search it.
        for flags in [O_RDONLY | O_DIRECTORY, O_SEARCH | O_DIRECTORY] {
            let descriptor = nested.path.withCString { Darwin.open($0, flags | O_CLOEXEC) }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }

            XCTAssertEqual(
                WorkspaceAnchoredFileSystem.volumeWriteCapabilities(descriptor: descriptor),
                VolumeWriteCapabilities(isReadOnly: false, exclusiveRename: true, swapRename: true)
            )
        }
        XCTAssertNil(WorkspaceAnchoredFileSystem.volumeWriteCapabilities(descriptor: -1))
    }

    func testWriteFailureNamesActionableErrorNumbersAndKeepsTheFallbackOtherwise() {
        let classified: [(Int32, WorkspaceAnchoredFileSystemError)] = [
            (ENOTSUP, .unsupportedVolume),
            (ENOSPC, .insufficientSpace),
            (EDQUOT, .insufficientSpace),
            (EROFS, .readOnlyVolume),
            (EPERM, .writeNotPermitted),
            (EACCES, .writeNotPermitted),
        ]
        for (code, reason) in classified {
            for fallback in [WorkspaceAnchoredFileSystemError.unreadable, .durabilityFailed] {
                XCTAssertEqual(
                    WorkspaceAnchoredFileSystem.writeFailure(errorNumber: code, otherwise: fallback),
                    reason,
                    "errno \(code)"
                )
            }
        }
        for code in [EIO, ENXIO, EFBIG, EINVAL, EXDEV] {
            XCTAssertEqual(
                WorkspaceAnchoredFileSystem.writeFailure(errorNumber: code, otherwise: .unreadable),
                .unreadable
            )
            XCTAssertEqual(
                WorkspaceAnchoredFileSystem.writeFailure(errorNumber: code, otherwise: .durabilityFailed),
                .durabilityFailed
            )
        }
    }

    private typealias VolumeWriteCapabilities = WorkspaceAnchoredFileSystem.VolumeWriteCapabilities

    private func volumeHooks(
        _ capabilities: VolumeWriteCapabilities,
        events: VolumeCheckEventRecorder
    ) -> WorkspaceAnchoredFileSystem.Hooks {
        WorkspaceAnchoredFileSystem.Hooks(
            eventHandler: events.record,
            volumeWriteCapabilities: { _ in capabilities }
        )
    }

    private func expectation(for fixture: WorkspaceWriteFixture) -> WorkspaceNoFollowFileWriteExpectation {
        fixture.originalIdentity.map { .existing($0) } ?? .missing
    }

    private func assertNothingStaged(
        _ fixture: WorkspaceWriteFixture,
        originalText: String?,
        events: VolumeCheckEventRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(events.staged, "nothing may be created before the volume check", file: file, line: line)
        if let originalText {
            XCTAssertEqual(try writeText(at: fixture.destination), originalText, file: file, line: line)
            XCTAssertEqual(
                try writeFileIdentity(at: fixture.destination),
                fixture.originalIdentity,
                file: file,
                line: line
            )
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path), file: file, line: line)
        }
        try assertNoWriteArtifacts(for: fixture, file: file, line: line)
        try assertFixtureSentinel(fixture, file: file, line: line)
    }
}

private final class VolumeCheckEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WorkspaceAnchoredFileSystem.Event] = []

    var staged: Bool {
        lock.withLock {
            events.contains(.temporaryFileCreated) || events.contains(.separateStagingAnchored)
        }
    }

    func record(_ event: WorkspaceAnchoredFileSystem.Event) {
        lock.withLock { events.append(event) }
    }
}

/// Records the identity behind each descriptor the volume check was asked about.
private final class VolumeCheckDescriptorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkspaceFileSystemIdentity] = []

    var identities: [WorkspaceFileSystemIdentity] {
        lock.withLock { storage }
    }

    func record(_ descriptor: Int32) {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return }
        lock.withLock {
            storage.append(WorkspaceFileSystemIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)))
        }
    }
}
