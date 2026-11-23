import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

/// The edit watcher must see every edit made after it is started, including one
/// made before its task first runs, or that edit never reaches autosave.
@MainActor
final class IOSDocumentEditWatcherTests: XCTestCase {
    func testEditBeforeTheWatcherTaskRunsReachesAutosave() async throws {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        entry.textTask?.cancel()
        await entry.textTask?.value

        harness.store.watchEdits(entry)
        // No suspension point between starting the watcher and this edit, so the
        // watcher's task has not run yet.
        let source = "edited before the watcher ran 繁中 👩🏽‍💻"
        handle.session.replaceText(source)

        await waitUntil { !port.written.isEmpty }
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, [source])
        XCTAssertFalse(handle.session.isDirty)
    }

    func testEditImmediatelyAfterOpenReachesAutosave() async throws {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let source = "edited as soon as open returned"
        handle.session.replaceText(source)

        await waitUntil { !port.written.isEmpty }
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, [source])
        XCTAssertFalse(handle.session.isDirty)
    }

    func testEditFromAnObserverDuringOpenReachesAutosave() async throws {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        let source = "edited by an observer of the first snapshot"
        var edited = false
        let observation = harness.store.observe { event in
            guard !edited, case let .snapshotChanged(snapshot) = event,
                  let session = harness.store.byIdentity[snapshot.revision.documentID]?.session
            else { return }
            edited = true
            session.replaceText(source)
        }
        defer { observation.cancel() }

        let handle = try await harness.openNote(text: "baseline")
        XCTAssertTrue(edited)
        XCTAssertEqual(handle.session.text, source)
        let port = try XCTUnwrap(harness.port(for: handle))

        await waitUntil { !port.written.isEmpty }
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, [source])
        XCTAssertFalse(handle.session.isDirty)
    }
}
