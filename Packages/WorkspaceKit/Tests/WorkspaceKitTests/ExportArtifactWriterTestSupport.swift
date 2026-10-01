import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

final class ExportArtifactWriterTests: XCTestCase {}

struct ExportWriterFixture {
    /// Canonical per-test base; only `directory` is the chosen folder.
    let base: URL
    let directory: URL
    let destination: URL
    let sentinel: URL
    let originalIdentity: WorkspaceFileSystemIdentity?

    /// The chosen folder's exact path without a trailing slash, as the writer spells it.
    var directoryPath: String {
        WorkspaceRootContainment.normalizedDirectoryPath(directory.path(percentEncoded: false))
    }

    var destinationPath: String {
        destination.path(percentEncoded: false)
    }
}

/// Records every writer boundary and, optionally, fails with an injected `errno` or runs a race
/// once, immediately before a named step. With a watched directory it also samples that
/// directory's entries and the descriptors naming it at every boundary.
final class ExportBoundaryProbe: @unchecked Sendable {
    typealias Step = ExportArtifactWriterStep

    private let lock = NSLock()
    private let failures: [Step: Int32]
    private var races: [Step: @Sendable () -> Void]
    private let watchedDirectory: String?
    /// Failures that become active only once `armingStep` is reached, for example to fail a
    /// boundary at the pre-publication re-proof but not at preflight.
    private let armedFailures: [Step: Int32]
    private let armingStep: Step?
    private var isArmed = false
    private var storedCalls: [ExportArtifactWriterCall] = []
    private var storedSnapshots: [[String]] = []
    private var storedDescriptorCounts: [Int] = []

    init(
        failures: [Step: Int32] = [:],
        races: [Step: @Sendable () -> Void] = [:],
        watchedDirectory: String? = nil,
        armedFailures: [Step: Int32] = [:],
        armingStep: Step? = nil
    ) {
        self.failures = failures
        self.races = races
        self.watchedDirectory = watchedDirectory
        self.armedFailures = armedFailures
        self.armingStep = armingStep
    }

    var calls: [ExportArtifactWriterCall] {
        lock.withLock { storedCalls }
    }

    var snapshots: [[String]] {
        lock.withLock { storedSnapshots }
    }

    var watchedDescriptorCounts: [Int] {
        lock.withLock { storedDescriptorCounts }
    }

    func calls(at step: Step) -> [ExportArtifactWriterCall] {
        calls.filter { $0.step == step }
    }

    /// The exact staged-file path the writer created (or tried to create).
    var stagedPath: String? {
        calls.first { $0.step == .createStaged && $0.operation == .open }?.path
    }

    var stagedURL: URL? {
        stagedPath.map { WorkspaceLiteralFileURL.fileURL(path: $0, isDirectory: false) }
    }

    /// The canonical item-replacement directory, derived from the staged path.
    var stagingDirectoryPath: String? {
        stagedPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    var stagingDirectoryURL: URL? {
        stagingDirectoryPath.map { WorkspaceLiteralFileURL.fileURL(path: $0, isDirectory: true) }
    }

    var createdStaging: Bool {
        stagedPath != nil
    }

    func hooks(
        stagingDirectory: (@Sendable (URL) throws -> URL)? = nil,
        volumeCapabilities: (@Sendable (URL) -> ExportArtifactVolumeCapabilities?)? = nil,
        isUbiquitous: (@Sendable (URL) -> Bool)? = nil,
        fileCoordinator: (@Sendable () -> NSFileCoordinator)? = nil,
        afterPreflight: (@Sendable () -> Void)? = nil,
        afterPublication: (@Sendable () -> Void)? = nil
    ) -> ExportArtifactWriterHooks {
        ExportArtifactWriterHooks(
            itemReplacementDirectory: stagingDirectory,
            volumeCapabilities: volumeCapabilities,
            isUbiquitous: isUbiquitous,
            fileCoordinator: fileCoordinator,
            observer: { [self] call in
                lock.withLock { storedCalls.append(call) }
            },
            beforeStep: { [self] step in
                sample()
                let race = lock.withLock { () -> (@Sendable () -> Void)? in
                    if step == armingStep {
                        isArmed = true
                    }
                    return races.removeValue(forKey: step)
                }
                race?()
            },
            injectedFailure: { [self] step in
                lock.withLock { failures[step] ?? (isArmed ? armedFailures[step] : nil) }
            },
            afterPreflight: afterPreflight,
            afterPublication: afterPublication
        )
    }

    private func sample() {
        guard let watchedDirectory else { return }
        let snapshot = (try? FileManager.default.contentsOfDirectory(atPath: watchedDirectory))?.sorted()
        let descriptors = exportOpenDescriptorCount(exactly: watchedDirectory)
        lock.withLock {
            if let snapshot {
                storedSnapshots.append(snapshot)
            }
            storedDescriptorCounts.append(descriptors)
        }
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
        // The writer refuses symlinked path components, and `/var` is a symlink.
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

    /// Runs one write. Any item-replacement directory the probe saw is removed at teardown, so
    /// an indeterminate test never leaks residue into the shared temporary-items folder.
    func export(
        _ text: String = "<!doctype html><title>Export</title>",
        to destination: URL,
        kind: ExportArtifactKind = .html,
        disposition: ExportArtifactDisposition,
        probe: ExportBoundaryProbe = ExportBoundaryProbe(),
        hooks: ExportArtifactWriterHooks? = nil,
        appPrivateRoot: URL? = nil,
        ownership: ExportArtifactOwnershipCheck = { _ in .permitted }
    ) -> ExportArtifactWriteOutcome {
        let outcome = ExportArtifactWriter.write(
            ExportArtifactWriteRequest(
                destinationURL: destination,
                kind: kind,
                disposition: disposition,
                bytes: Data(text.utf8)
            ),
            appPrivateRoot: appPrivateRoot,
            ownership: ownership,
            hooks: hooks ?? probe.hooks()
        )
        if let staging = probe.stagingDirectoryPath {
            addTeardownBlock {
                try? FileManager.default.removeItem(atPath: staging)
            }
        }
        return outcome
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
        try WorkspaceFileSystemIdentity(exportStatus: status(at: url.path(percentEncoded: false)))
    }

    func status(at path: String) throws -> stat {
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    func permissionBits(at url: URL) throws -> mode_t {
        try status(at: url.path(percentEncoded: false)).st_mode & mode_t(0o7777)
    }

    func linkCount(at url: URL) throws -> Int {
        try Int(status(at: url.path(percentEncoded: false)).st_nlink)
    }

    func exists(_ path: String?) -> Bool {
        guard let path else { return false }
        var status = stat()
        return path.withCString { Darwin.lstat($0, &status) } == 0
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

    /// The writer touched the chosen folder only through metadata reads of its own path
    /// (`fstatat`, `getattrlist`) and calls on the exact leaf; every other path lies in the
    /// item-replacement directory, outside it. The only descriptors ever opened are the existing
    /// leaf (to read its kernel spelling) and the staged file.
    func assertTouchedOnlyLeafParentAndStaging(
        _ probe: ExportBoundaryProbe,
        fixture: ExportWriterFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let staging = probe.stagingDirectoryPath
        for call in probe.calls {
            if call.operation == .open {
                XCTAssertTrue(
                    call.path == fixture.destinationPath || call.path == probe.stagedPath,
                    "only the leaf and the staged file are opened: \(call)",
                    file: file,
                    line: line
                )
            }
            if call.path == fixture.directoryPath {
                XCTAssertTrue(
                    [.fstatat, .fullPath].contains(call.operation),
                    "the chosen folder is only ever read by metadata: \(call)",
                    file: file,
                    line: line
                )
            } else if call.step == .inspectFoundationScaffolding {
                XCTAssertEqual(call.operation, .fstatat, "shared ancestors are metadata-only", file: file, line: line)
                let temporary = "\(fixture.directoryPath)/.TemporaryItems"
                XCTAssertTrue([temporary, "\(temporary)/folders.\(getuid())"].contains(call.path),
                              "only Foundation scaffolding is observed: \(call)", file: file, line: line)
            } else if call.path != fixture.destinationPath {
                XCTAssertFalse(
                    ExportArtifactWriter.pathLies(call.path, inside: fixture.directoryPath, caseSensitive: false),
                    "\(call)",
                    file: file,
                    line: line
                )
                if let staging {
                    // Foundation's returned spelling (for example through `/var`) is read once by
                    // metadata to find its canonical spelling; every later call uses that spelling.
                    let returnedSpelling = [.inspectStagingDirectory, .canonicalizeStagingDirectory]
                        .contains(call.step)
                        && (call.path as NSString).lastPathComponent == (staging as NSString).lastPathComponent
                    XCTAssertTrue(returnedSpelling || call.path.hasPrefix(staging), "\(call)", file: file, line: line)
                }
            }
        }
    }
}

/// Open descriptors of this process whose kernel path is `directory` or below it.
func exportOpenDescriptorCount(under directory: String) -> Int {
    let root = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return exportOpenDescriptorPaths().filter { $0 == root || $0.hasPrefix(root + "/") }.count
}

/// Open descriptors of this process whose kernel path is exactly `directory`.
func exportOpenDescriptorCount(exactly directory: String) -> Int {
    let root = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return exportOpenDescriptorPaths().filter { $0 == root }.count
}

private func exportOpenDescriptorPaths() -> [String] {
    let byteCount = Darwin.proc_pidinfo(Darwin.getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard byteCount > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride)
    let used = Darwin.proc_pidinfo(Darwin.getpid(), PROC_PIDLISTFDS, 0, &descriptors, byteCount)
    guard used >= 0 else { return [] }
    var paths: [String] = []
    for info in descriptors.prefix(Int(used) / stride)
        where info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE)
    {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(info.proc_fd, F_GETPATH, &buffer) != -1 else { continue }
        paths.append(String(cString: buffer).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
    return paths
}

final class DescriptorCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] {
        lock.withLock { stored }
    }

    func append(_ value: Int) {
        lock.withLock { stored.append(value) }
    }
}

final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    var values: [URL] {
        lock.withLock { stored }
    }

    func append(_ value: URL) {
        lock.withLock { stored.append(value) }
    }
}
