import Foundation
@testable import WorkspaceKit
import XCTest

final class WorkspaceDirectoryScannerResilienceTests: XCTestCase {
    func testEntryRemovedDuringEnumerationIsSkippedInsteadOfFailingTheScan() async throws {
        let root = try makeTemporaryDirectory()
        try write("a", to: root.appendingPathComponent("a.md"))
        try write("b", to: root.appendingPathComponent("b.md"))
        try write("c", to: root.appendingPathComponent("c.md"))
        let firstVisited = FirstVisitedEntry()
        // Enumeration order is unspecified, so the first visit removes every other sibling: the
        // enumerator already listed them, and it visits them after they are gone.
        let scanner = WorkspaceDirectoryScanner(entryVisitHook: { url in
            guard firstVisited.claim(url.lastPathComponent) else { return }
            for name in ["a.md", "b.md", "c.md"] where name != url.lastPathComponent {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent().appendingPathComponent(name)
                )
            }
        })

        // `snapshotCapture` keeps the literal spelling, as the app's reload does.
        let snapshot = try await scanner.snapshotCapture(root: root).snapshot

        let survivor = try XCTUnwrap(firstVisited.name)
        XCTAssertEqual(snapshot.entries.map(\.relativePath), [survivor])
    }

    func testUnreadableFileAndDirectoryDoNotFailTheScan() async throws {
        let root = try makeTemporaryDirectory()
        let lockedFile = root.appendingPathComponent("locked.md")
        let lockedDirectory = root.appendingPathComponent("locked-dir", isDirectory: true)
        try write("a", to: root.appendingPathComponent("a.md"))
        try write("locked", to: lockedFile)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try write("inner", to: lockedDirectory.appendingPathComponent("inner.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDirectory.path)
        }
        try XCTSkipIf(
            FileManager.default.isReadableFile(atPath: lockedFile.path),
            "Running as a user that bypasses file permissions"
        )

        let snapshot = try await WorkspaceDirectoryScanner().snapshotCapture(root: root).snapshot

        let paths = Set(snapshot.entries.map(\.relativePath))
        XCTAssertTrue(paths.isSuperset(of: ["a.md", "locked.md", "locked-dir"]), "\(paths)")
        XCTAssertFalse(paths.contains("locked-dir/inner.md"))
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDirectoryScannerResilienceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class FirstVisitedEntry: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: String?

    var name: String? {
        lock.withLock { claimed }
    }

    func claim(_ candidate: String) -> Bool {
        lock.withLock {
            guard claimed == nil else { return false }
            claimed = candidate
            return true
        }
    }
}
