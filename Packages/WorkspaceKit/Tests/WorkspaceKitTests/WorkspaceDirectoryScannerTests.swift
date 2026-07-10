@testable import WorkspaceKit
import XCTest

final class WorkspaceDirectoryScannerTests: XCTestCase {
    func testSnapshotClassifiesWorkspaceEntries() async throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("content"),
            withIntermediateDirectories: true
        )
        try "# Post".write(to: root.appendingPathComponent("content/post.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("hero.png"))
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)
        let kindsByPath = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.relativePath, $0.kind) })

        XCTAssertEqual(kindsByPath["content"], .directory)
        XCTAssertEqual(kindsByPath["content/post.md"], .markdown)
        XCTAssertEqual(kindsByPath["hero.png"], .image)
        XCTAssertEqual(kindsByPath["package.json"], .other)
        XCTAssertFalse(snapshot.entries.contains { $0.relativePath.hasPrefix("/") })
    }

    func testCancellationPropagatesIntoEnumerationWorker() async throws {
        let root = try makeTemporaryDirectory()
        try "Body".write(
            to: root.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        let gate = ScannerCancellationGate()
        let scanner = WorkspaceDirectoryScanner(entryVisitHook: { _ in
            gate.waitForRelease()
        })

        let task = Task {
            try await scanner.snapshot(root: root)
        }
        XCTAssertTrue(gate.waitUntilEntered())
        task.cancel()
        gate.release()

        do {
            _ = try await task.value
            XCTFail("Cancelled enumeration unexpectedly produced a snapshot")
        } catch is CancellationError {
            // Expected: the structured utility worker saw cancellation after its entry hook.
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDirectoryScannerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Semaphores explicitly serialize the test hook's cross-task handoff.
private final class ScannerCancellationGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func waitForRelease() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func release() {
        released.signal()
    }
}
