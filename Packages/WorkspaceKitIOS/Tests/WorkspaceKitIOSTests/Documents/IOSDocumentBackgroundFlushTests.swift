import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentBackgroundFlushTests: XCTestCase {
    func testSlowSaveDoesNotDelayRecoveryOfAnotherDirtyDocument() async throws {
        let timing = IOSDocumentTiming(
            autosaveDelayNanoseconds: 60_000_000_000,
            backgroundFlushNanoseconds: 30_000_000_000
        )
        let harness = DocumentIOHarness(timing: timing)
        let first = try await harness.openNote(text: "a", relativePath: "A.md", resourceID: Data("a".utf8))
        let second = try await harness.openNote(text: "b", relativePath: "B.md", resourceID: Data("b".utf8))
        let ports = try [XCTUnwrap(harness.port(for: first)), XCTUnwrap(harness.port(for: second))]
        ports.forEach { $0.blocksSaves = true }
        first.session.replaceText("draft a")
        second.session.replaceText("draft b")

        let flush = Task { await harness.store.flushForBackground() }
        // Both recovery records exist while both provider saves are still parked.
        await waitUntil {
            let sources = await Set(harness.recovery.list().records.map(\.source))
            return sources == ["draft a", "draft b"] && ports.allSatisfy { $0.parked == 1 }
        }
        XCTAssertTrue(ports.allSatisfy(\.written.isEmpty))
        ports.forEach { $0.releaseOne() }
        let outcomes = await flush.value
        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            guard case .saved = outcome else { return XCTFail("expected a confirmed save, got \(outcome)") }
        }
    }
}

extension IOSDocumentBackgroundFlushTests {
    func testLaterSaveRemovesTheCheckpointOfATimedOutBackgroundFlush() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = DocumentIOHarness(recovery: IOSDocumentRecoveryStore(directory: directory))
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        handle.session.replaceText("first draft")
        port.blocksSaves = true
        let outcomes = await harness.store.flushForBackground()
        guard case .recovered = outcomes.first else { return XCTFail("expected a timed-out flush") }
        await waitUntil { port.parked >= 1 }
        // Edited before the parked save lands: the session is then dirty past that save's
        // version, so the equal-version discard cannot remove the checkpoint first.
        handle.session.replaceText("second draft")
        port.blocksSaves = false
        port.releaseOne()
        await waitUntil { port.written.count == 1 }

        _ = try await harness.store.save(handle.identity)
        let list = await harness.store.recoveryList()
        XCTAssertTrue(list.records.isEmpty, "the older checkpoint stayed on disk")
    }

    func testNewerCheckpointReplacesTheOlderOneOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = DocumentIOHarness(recovery: IOSDocumentRecoveryStore(directory: directory))
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        handle.session.replaceText("first draft")
        _ = await harness.store.flushForBackground()
        handle.session.replaceText("second draft")
        _ = await harness.store.flushForBackground()
        let list = await harness.store.recoveryList()
        XCTAssertEqual(list.records.map(\.source), ["second draft"])
    }
}
