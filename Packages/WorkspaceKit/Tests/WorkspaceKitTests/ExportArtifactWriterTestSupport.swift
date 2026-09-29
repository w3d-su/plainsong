import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class ExportArtifactWriterTests: XCTestCase {}

struct ExportWriterFixture {
    /// Canonical per-test base; only `directory` is the selected parent.
    let base: URL
    let directory: URL
    let destination: URL
    let sentinel: URL
    let originalIdentity: WorkspaceFileSystemIdentity?
}

/// Records every observable boundary of one export operation and, optionally, fails or races
/// at a named syscall boundary. Directory snapshots prove the sibling namespace at each point.
final class ExportBoundaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [WorkspaceAnchoredFileSystem.InjectedCall: WorkspaceAnchoredFileSystemError]
    private let races: [WorkspaceAnchoredFileSystem.InjectedCall: @Sendable () -> Void]
    private let snapshotDirectory: URL?
    private var storedEvents: [WorkspaceAnchoredFileSystem.Event] = []
    private var storedCalls: [WorkspaceAnchoredFileSystem.InjectedCall] = []
    private var storedObservations: [WorkspaceAnchoredFileSystem.TemporaryArtifactObservation] = []
    private var storedSnapshots: [[String]] = []

    init(
        failures: [WorkspaceAnchoredFileSystem.InjectedCall: WorkspaceAnchoredFileSystemError] = [:],
        races: [WorkspaceAnchoredFileSystem.InjectedCall: @Sendable () -> Void] = [:],
        snapshotDirectory: URL? = nil
    ) {
        self.failures = failures
        self.races = races
        self.snapshotDirectory = snapshotDirectory
    }

    var events: [WorkspaceAnchoredFileSystem.Event] {
        lock.withLock { storedEvents }
    }

    var calls: [WorkspaceAnchoredFileSystem.InjectedCall] {
        lock.withLock { storedCalls }
    }

    var snapshots: [[String]] {
        lock.withLock { storedSnapshots }
    }

    var stagingName: String? {
        lock.withLock {
            storedObservations.compactMap { observation -> String? in
                if case let .created(name) = observation { return name }
                return nil
            }.last
        }
    }

    var createdStaging: Bool {
        stagingName != nil
    }

    func hooks(
        volumeCapabilities: (@Sendable (Int32) -> ExportArtifactVolumeCapabilities)? = nil,
        afterPreflight: (@Sendable () -> Void)? = nil,
        afterPublication: (@Sendable () -> Void)? = nil
    ) -> ExportArtifactWriterHooks {
        ExportArtifactWriterHooks(
            fileSystem: WorkspaceAnchoredFileSystem.Hooks(
                eventHandler: { [self] event in
                    let snapshot = snapshot()
                    lock.withLock {
                        storedEvents.append(event)
                        if let snapshot { storedSnapshots.append(snapshot) }
                    }
                },
                injectedFailure: { [self] call in
                    let snapshot = snapshot()
                    let race = lock.withLock { () -> (@Sendable () -> Void)? in
                        storedCalls.append(call)
                        if let snapshot { storedSnapshots.append(snapshot) }
                        return races[call]
                    }
                    race?()
                    return lock.withLock { failures[call] }
                },
                temporaryArtifactObserver: { [self] observation in
                    lock.withLock { storedObservations.append(observation) }
                }
            ),
            volumeCapabilities: volumeCapabilities,
            afterPreflight: afterPreflight,
            afterPublication: afterPublication
        )
    }

    private func snapshot() -> [String]? {
        guard let snapshotDirectory else { return nil }
        return try? FileManager.default.contentsOfDirectory(
            atPath: snapshotDirectory.path(percentEncoded: false)
        ).sorted()
    }
}

extension ExportArtifactWriterTests {
    static let sentinelName = "sentinel.txt"

    func makeExportFixture(
        leaf: String = "export.html",
        originalText: String? = nil
    ) throws -> ExportWriterFixture {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportArtifactWriterTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // The writer refuses symlinked parent components, and `/var` is a symlink.
        let base = try WorkspaceFileSystemRootAuthority(rootURL: temporary).canonicalRootURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporary)
        }
        let directory = base.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent(Self.sentinelName)
        try Data("sentinel".utf8).write(to: sentinel)
        let destination = directory.appendingPathComponent(leaf, isDirectory: false)
        var originalIdentity: WorkspaceFileSystemIdentity?
        if let originalText {
            try Data(originalText.utf8).write(to: destination)
            originalIdentity = try identity(at: destination)
        }
        return ExportWriterFixture(
            base: base,
            directory: directory,
            destination: destination,
            sentinel: sentinel,
            originalIdentity: originalIdentity
        )
    }

    func export(
        _ text: String = "<!doctype html><title>Export</title>",
        to destination: URL,
        kind: ExportArtifactKind = .html,
        disposition: ExportArtifactDisposition,
        hooks: ExportArtifactWriterHooks = .production,
        ownership: ExportArtifactOwnershipCheck = { _ in .permitted }
    ) -> ExportArtifactWriteOutcome {
        ExportArtifactWriter.write(
            ExportArtifactWriteRequest(
                destinationURL: destination,
                kind: kind,
                disposition: disposition,
                bytes: Data(text.utf8)
            ),
            ownership: ownership,
            hooks: hooks
        )
    }

    func entries(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        ).sorted()
    }

    func text(at url: URL) throws -> String {
        try XCTUnwrap(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    func identity(at url: URL) throws -> WorkspaceFileSystemIdentity {
        var status = stat()
        guard url.path(percentEncoded: false).withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return WorkspaceFileSystemIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    func linkCount(at url: URL) throws -> Int {
        var status = stat()
        guard url.path(percentEncoded: false).withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(status.st_nlink)
    }

    func operationSiblings(in directory: URL) throws -> [String] {
        try entries(in: directory).filter { $0.hasPrefix(".plainsong-") }
    }

    func requireIndeterminate(
        _ outcome: ExportArtifactWriteOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ExportArtifactIndeterminateWrite? {
        guard case let .indeterminate(result) = outcome else {
            XCTFail("Expected indeterminate, got \(outcome)", file: file, line: line)
            return nil
        }
        return result
    }

    func requireCommitted(
        _ outcome: ExportArtifactWriteOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ExportArtifactCommit? {
        guard case let .committed(result) = outcome else {
            XCTFail("Expected committed, got \(outcome)", file: file, line: line)
            return nil
        }
        return result
    }

    func stagingURL(_ name: String?, in fixture: ExportWriterFixture) -> URL? {
        name.map { fixture.directory.appendingPathComponent($0, isDirectory: false) }
    }
}

/// Open descriptors of this process whose kernel path is `directory` or below it.
func exportOpenDescriptorCount(under directory: URL) -> Int {
    let root = directory.path(percentEncoded: false).trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
    )
    let byteCount = Darwin.proc_pidinfo(Darwin.getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard byteCount > 0 else { return -1 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride)
    let used = Darwin.proc_pidinfo(Darwin.getpid(), PROC_PIDLISTFDS, 0, &descriptors, byteCount)
    guard used >= 0 else { return -1 }
    var count = 0
    for info in descriptors.prefix(Int(used) / stride)
        where info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE)
    {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(info.proc_fd, F_GETPATH, &buffer) != -1 else { continue }
        let path = String(cString: buffer).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        if path == root || path.hasPrefix(root + "/") { count += 1 }
    }
    return count
}
