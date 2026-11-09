import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

final class SharedRootCountingScanner: WorkspaceDirectoryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    let gate = SharedRootScanGate()

    func count(_ root: URL) -> Int {
        lock.withLock { counts[root.resolvingSymlinksInPath().path, default: 0] }
    }

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        try await snapshotCapture(root: root, pruning: .none)
    }

    func snapshotCapture(root: URL, pruning: WorkspaceScanPruning) async throws -> WorkspaceDirectorySnapshotCapture {
        lock.withLock { counts[root.resolvingSymlinksInPath().path, default: 0] += 1 }
        await gate.waitIfHeld()
        return try await WorkspaceDirectoryScanner().snapshotCapture(root: root, pruning: pruning)
    }
}

actor SharedRootScanGate {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdNext() {
        held = true
    }

    func waitIfHeld() async {
        guard held else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        held = false
        continuation?.resume()
        continuation = nil
    }
}

final class SharedRootOperationStore: WorkspaceMutationOperationRecoveryPersisting {
    var records: [UUID: WorkspaceMutationOperationRecoveryRecord] = [:]
    var onUpsert: (() -> Void)?
    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        Array(records.values)
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws {
        records[record.id] = record
        onUpsert?()
    }

    func remove(id: UUID) throws {
        records[id] = nil
    }
}

@MainActor
class SharedRootAppTestCase: XCTestCase {
    var directory: URL!
    var primary: AppState!
    var second: AppState!
    var scanner: SharedRootCountingScanner!
    var operationStore: SharedRootOperationStore!
    var scopeStarts = 0
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "SharedRoot-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scanner = SharedRootCountingScanner()
        operationStore = SharedRootOperationStore()
        primary = AppState(
            directoryScanner: scanner,
            workspaceSearchDebounceNanoseconds: 0,
            workspaceMutationOperationRecoveryStore: operationStore,
            shouldRestoreLastOpenedFile: false, userDefaults: defaults
        )
        primary.registry.workspaceScopeStarter = { [weak self] root in
            self?.scopeStarts += 1
            return SecurityScopedAccess.startAccessing(root)
        }
        second = primary.makeSiblingFacade(admitsFileOperations: true)
    }

    override func tearDown() async throws {
        operationStore.onUpsert = nil
        await scanner.gate.release()
        primary?.workspaceWatcher?.stop()
        second?.workspaceWatcher?.stop()
        primary = nil
        second = nil
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func makeRoot(_ name: String, files: [String: String] = ["a.md": "alpha text", "b.md": "beta text"]) throws -> URL {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: file)
        }
        return root
    }

    func open(_ facade: AppState, root: URL, keepWatcher: Bool = false) async throws {
        try facade.openWorkspace(url: root, rememberAsLastOpened: false)
        await facade.workspaceReloadTask?.value
        try await waitUntil("root capture installs") {
            facade.workspaceInstalledCaptureGeneration == facade.workspaceGeneration && facade.workspaceTree != nil
        }
        XCTAssertNil(facade.presentedError)
        if !keepWatcher {
            facade.workspaceWatcher?.stop()
        }
    }

    func openPair(root: URL, keepWatcher: Bool = false) async throws {
        try await open(primary, root: root, keepWatcher: keepWatcher)
        try second.openWorkspace(url: root, rememberAsLastOpened: false)
        try await waitUntil("second tree installs") { self.second.workspaceTree != nil }
        XCTAssertTrue(primary.workspaceRootContext === second.workspaceRootContext)
    }

    func node(_ path: String, in facade: AppState) -> WorkspaceFileNode? {
        guard let tree = facade.workspaceTree else { return nil }
        return facade.firstNode(in: tree.root, relativePath: path)
    }

    func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
        throw CocoaError(.userCancelled)
    }
}
