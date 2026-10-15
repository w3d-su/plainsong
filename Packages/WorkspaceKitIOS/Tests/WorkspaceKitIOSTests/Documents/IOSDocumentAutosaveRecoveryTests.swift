import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentAutosaveRecoveryTests: XCTestCase {
    func testRetainedCloseReschedulesAnAutosaveThatExitedDuringTheCloseBarrier() async throws {
        let race = try await parkedCloseAfterAutosaveExited()
        race.releaseClose()
        guard case let .retained(receipt) = try await race.closing.value else {
            return XCTFail("a newer draft must be retained")
        }
        XCTAssertNotNil(receipt)
        XCTAssertGreaterThan(race.entry.autosaveGeneration, race.exitedAutosaveGeneration,
                             "restored authority must schedule a fresh autosave")
        let resumed = try XCTUnwrap(race.entry.autosaveTask)
        await resumed.value
        XCTAssertEqual(race.port.written.map { String(data: $0, encoding: .utf8) }, [race.source])
        XCTAssertFalse(race.handle.session.isDirty)
        XCTAssertEqual(race.handle.session.text, race.source)
        XCTAssertEqual(race.handle.session.version, race.version)
        XCTAssertFalse(race.entry.lease.isReleased)
        XCTAssertEqual(race.port.openCalls, 2)
        let recovery = await race.harness.recovery.list()
        XCTAssertTrue(recovery.records.contains {
            $0.documentID == race.handle.identity.rawValue
                && $0.source == race.source && $0.revisionVersion == race.version
        })
    }

    func testReadOnlyReopenDoesNotResumeOriginalFileAutosave() async throws {
        let race = try await parkedCloseAfterAutosaveExited()
        race.port.canWrite = false
        race.releaseClose()
        guard case .retained = try await race.closing.value else { return XCTFail("retain read-only draft") }
        XCTAssertEqual(race.entry.autosaveGeneration, race.exitedAutosaveGeneration)
        await race.entry.autosaveTask?.value
        XCTAssertTrue(race.port.written.isEmpty)
        XCTAssertEqual(race.harness.store.state(for: race.handle.identity)?.canWrite, false)
        XCTAssertEqual(race.handle.session.text, race.source)
        XCTAssertEqual(race.handle.session.version, race.version)
        XCTAssertTrue(race.handle.session.isDirty)
    }

    func testConflictingReopenDoesNotResumeOriginalFileAutosave() async throws {
        let race = try await parkedCloseAfterAutosaveExited()
        race.port.openedData = Data("external bytes during close".utf8)
        race.releaseClose()
        guard case .retained = try await race.closing.value else { return XCTFail("retain conflicting draft") }
        guard case .conflict = race.harness.store.state(for: race.handle.identity) else {
            return XCTFail("different disk bytes must fence the original")
        }
        XCTAssertEqual(race.entry.autosaveGeneration, race.exitedAutosaveGeneration)
        await race.entry.autosaveTask?.value
        XCTAssertTrue(race.port.written.isEmpty)
        XCTAssertEqual(race.handle.session.text, race.source)
        XCTAssertEqual(race.handle.session.version, race.version)
        XCTAssertTrue(race.handle.session.isDirty)
    }

    private func parkedCloseAfterAutosaveExited() async throws -> SuspendedClose {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        harness.ports.openedData = Data("baseline".utf8)
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        var closeContinuation: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { closeContinuation = $0 } }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { closeContinuation != nil }
        let generation = entry.autosaveGeneration
        let source = "N+1 retained during close 繁中 👩🏽‍💻"
        handle.session.replaceText(source)
        let version = handle.session.version
        await waitUntil { entry.autosaveGeneration > generation }
        let autosave = try XCTUnwrap(entry.autosaveTask)
        await autosave.value
        XCTAssertTrue(port.written.isEmpty, "the parked close must fence that old autosave")
        XCTAssertTrue(entry.isClosing)
        let releaseClose: @MainActor () -> Void = {
            closeContinuation?.resume()
            closeContinuation = nil
        }
        return SuspendedClose(harness: harness, handle: handle, entry: entry, port: port,
                              source: source, version: version,
                              exitedAutosaveGeneration: entry.autosaveGeneration,
                              closing: closing, releaseClose: releaseClose)
    }
}

private struct SuspendedClose {
    let harness: DocumentIOHarness
    let handle: IOSDocumentHandle
    let entry: IOSDocumentEntry
    let port: ScriptedFilePort
    let source: String
    let version: Int
    let exitedAutosaveGeneration: UInt64
    let closing: Task<IOSDocumentCloseOutcome, Error>
    let releaseClose: @MainActor () -> Void
}
