import Foundation
import WorkspaceKit

protocol WorkspaceDirectoryScanning: Sendable {
    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture
    func snapshotCapture(
        root: URL,
        pruning: WorkspaceScanPruning
    ) async throws -> WorkspaceDirectorySnapshotCapture
}

extension WorkspaceDirectoryScanning {
    /// Scanners that cannot prune (test doubles) enumerate everything.
    func snapshotCapture(
        root: URL,
        pruning _: WorkspaceScanPruning
    ) async throws -> WorkspaceDirectorySnapshotCapture {
        try await snapshotCapture(root: root)
    }
}

extension WorkspaceDirectoryScanner: WorkspaceDirectoryScanning {}
