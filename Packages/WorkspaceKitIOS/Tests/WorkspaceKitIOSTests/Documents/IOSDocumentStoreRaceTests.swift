import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentStoreRaceTests: XCTestCase {
    func testBlockedSaveThenNewerEditKeepsLiveSourceDirtyUntilSecondSave() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "base")
        handle.session.replaceText("v1")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "v1 entered")
        port.onSaveEntered = { entered.fulfill() }
        let first = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)

        handle.session.replaceText("v2 繁中 👩🏽‍💻")
        let liveVersion = handle.session.version
        let secondEntered = expectation(description: "v2 entered")
        port.onSaveEntered = { secondEntered.fulfill() }
        let second = Task { try await harness.store.save(handle.identity) }
        await Task.yield()
        XCTAssertEqual(port.peakInFlight, 1)
        XCTAssertEqual(port.inFlight, 1)

        port.releaseOne()
        let firstAck = try await first.value
        XCTAssertEqual(firstAck.savedText, "v1")
        XCTAssertEqual(firstAck.revision.version, 1)
        XCTAssertEqual(handle.session.text, "v2 繁中 👩🏽‍💻")
        XCTAssertEqual(handle.session.version, liveVersion)
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, ["v1"])

        await fulfillment(of: [secondEntered], timeout: 2)
        XCTAssertEqual(port.peakInFlight, 1)
        port.releaseOne()
        let secondAck = try await second.value
        XCTAssertEqual(secondAck.savedText, "v2 繁中 👩🏽‍💻")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(handle.session.text, "v2 繁中 👩🏽‍💻")
        XCTAssertEqual(handle.session.version, liveVersion)
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, ["v1", "v2 繁中 👩🏽‍💻"])
    }

    func testStaleSaveCompletionCannotRewriteNewerSource() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "base")
        handle.session.replaceText("v1")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "save")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        handle.session.replaceText("v2 繁中 👩🏽‍💻")
        let liveVersion = handle.session.version
        port.releaseOne()
        let acknowledgement = try await saving.value
        port.replay(acknowledgement.operationID)
        XCTAssertEqual(handle.session.text, "v2 繁中 👩🏽‍💻")
        XCTAssertEqual(handle.session.version, liveVersion)
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(port.written.count, 1)
    }

    func testSerializedWriterNeverOverlapsProviderSaves() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "one")
        handle.session.replaceText("two")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "first")
        port.onSaveEntered = { entered.fulfill() }
        let first = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        handle.session.replaceText("three")
        let second = Task { try await harness.store.save(handle.identity) }
        await Task.yield()
        XCTAssertEqual(port.peakInFlight, 1, "removing the writer queue makes this overlap")
        port.releaseOne()
        _ = try await first.value
        let next = expectation(description: "second")
        port.onSaveEntered = { next.fulfill() }
        await fulfillment(of: [next], timeout: 2)
        XCTAssertEqual(port.peakInFlight, 1)
        port.releaseOne()
        _ = try await second.value
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, ["two", "three"])
    }

    func testAliasedOpensShareOneSessionAndOneWriter() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        harness.ports.openedData = Data("shared".utf8)
        let firstLocation = harness.location(relativePath: "Note.md", generation: 1)
        let aliasLocation = harness.location(relativePath: "Alias.md", generation: 1, resourceID: Data("resource".utf8))
        let lease = harness.directoryLease(generation: 1)
        let aliasLease = harness.directoryLease(generation: 1)
        let firstTask = Task { try await harness.store.open(firstLocation, lease: lease) }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let secondTask = Task { try await harness.store.open(aliasLocation, lease: aliasLease) }
        await Task.yield()
        XCTAssertEqual(harness.ports.created.count, 1)
        harness.ports.created[0].releaseOne()
        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertTrue(first.session === second.session)
        XCTAssertEqual(first.identity, second.identity)
        first.session.replaceText("edited")
        let port = try XCTUnwrap(harness.port(for: first))
        port.blocksSaves = true
        let entered = expectation(description: "save")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(second.identity) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(port.peakInFlight, 1)
        port.releaseOne()
        _ = try await saving.value
        XCTAssertFalse(first.session.isDirty)
        XCTAssertEqual(harness.ports.created.count, 1)
    }

    func testUnscopedUnicodeSpellingsDoNotShareAWriter() async throws {
        let harness = DocumentIOHarness()
        let composed = "Caf\u{00E9}.md"
        let decomposed = "Cafe\u{0301}.md"
        let first = try await harness.openNote(text: "composed", relativePath: composed, resourceID: nil)
        let second = try await harness.openNote(text: "decomposed", relativePath: decomposed, resourceID: nil)
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertFalse(first.session === second.session)
        first.session.replaceText("changed")
        let port = try XCTUnwrap(harness.port(for: first))
        port.blocksSaves = true
        let entered = expectation(description: "save")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(first.identity) }
        await fulfillment(of: [entered], timeout: 2)
        port.releaseOne()
        _ = try await saving.value
        XCTAssertEqual(second.session.text, "decomposed")
        XCTAssertFalse(second.session.isDirty)
        XCTAssertEqual(harness.port(for: second)?.written.count, 0)
    }

    func testStaleGenerationSaveCannotReviseTheReplacement() async throws {
        let harness = DocumentIOHarness()
        let original = try await harness.openNote(text: "base")
        original.session.replaceText("snapshot-v1")
        let oldPort = try XCTUnwrap(harness.port(for: original))
        oldPort.blocksSaves = true
        let entered = expectation(description: "old save")
        oldPort.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(original.identity) }
        await fulfillment(of: [entered], timeout: 2)
        original.session.replaceText("live-v2")
        let liveVersion = original.session.version
        harness.ports.openedData = Data("fresh".utf8)
        let replacement = try await harness.openNote(text: "fresh", generation: 2)
        XCTAssertFalse(original.session === replacement.session)
        oldPort.releaseOne()
        do {
            _ = try await saving.value
            XCTFail("stale generation completion must not acknowledge the replacement")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .documentChanged)
        }
        XCTAssertEqual(original.session.text, "live-v2")
        XCTAssertEqual(original.session.version, liveVersion)
        XCTAssertEqual(replacement.session.text, "fresh")
        XCTAssertEqual(replacement.session.version, 0)
        XCTAssertFalse(replacement.session.isDirty)
    }

    func testCancelledSaveKeepsTheDraftAndRetryCanFinish() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "draft")
        handle.session.replaceText("draft plus")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "save")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        saving.cancel()
        XCTAssertEqual(handle.session.text, "draft plus")
        XCTAssertTrue(handle.session.isDirty)
        port.releaseOne()
        _ = try? await saving.value
        XCTAssertEqual(handle.session.text, "draft plus")
        handle.session.replaceText("draft plus again")
        let retryEntered = expectation(description: "retry")
        port.onSaveEntered = { retryEntered.fulfill() }
        let retry = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [retryEntered], timeout: 2)
        port.releaseOne()
        _ = try await retry.value
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(handle.session.text, "draft plus again")
    }
}
