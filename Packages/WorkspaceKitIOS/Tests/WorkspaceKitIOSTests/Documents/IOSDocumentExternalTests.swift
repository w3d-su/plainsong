import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentExternalTests: XCTestCase {
    func testExternalReadDroppedAfterGenerationSessionOrEditChanges() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "local")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        handle.session.replaceText("edited during read")
        let editedVersion = handle.session.version
        await harness.coordinator.unblockReads()
        await waitUntil { harness.events.contains { event in
            if case .recoveryPersisted = event {
                return true
            }
            if case .failed = event {
                return true
            }
            return false
        } }
        let proposals = reloadProposals(in: harness.events)
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(handle.session.text, "edited during read")
        XCTAssertEqual(handle.session.version, editedVersion)
        XCTAssertTrue(reloadProposals(in: harness.events).isEmpty)
    }

    func testStaleExternalReadCannotUpdateAReplacementRoot() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "local")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        let replacement = try await harness.openNote(text: "fresh", generation: 2)
        await harness.coordinator.unblockReads()
        await waitUntil { await harness.coordinator.completedReads() == 1 }
        XCTAssertEqual(replacement.session.text, "fresh")
        XCTAssertEqual(replacement.session.version, 0)
        XCTAssertFalse(replacement.session.isDirty)
        XCTAssertTrue(reloadProposals(in: harness.events).isEmpty)
        _ = handle
    }

    func testCleanExternalReloadStaysAProposalUntilAcknowledged() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "clean")
        let version = handle.session.version
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("from disk".utf8))
        port.emit(.externalChange)
        await waitUntil { !reloadProposals(in: harness.events).isEmpty }
        XCTAssertEqual(handle.session.text, "clean")
        XCTAssertEqual(handle.session.version, version)
        XCTAssertFalse(handle.session.isDirty)
        let proposal = try XCTUnwrap(reloadProposals(in: harness.events).first)

        harness.store.acknowledgeExternalReload(
            operationID: proposal.operationID,
            outcome: .installed(IOSDocumentRevision(documentID: handle.identity, version: version))
        )
        XCTAssertEqual(handle.session.text, "clean")
        XCTAssertFalse(handle.session.isDirty)

        handle.session.replaceText(proposal.text)
        harness.store.acknowledgeExternalReload(
            operationID: proposal.operationID,
            outcome: .installed(IOSDocumentRevision(documentID: handle.identity, version: handle.session.version))
        )
        XCTAssertEqual(handle.session.text, "from disk")
        XCTAssertFalse(handle.session.isDirty)
    }

    func testDeferredReloadDoesNotChangeBaseline() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "clean")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("other".utf8))
        port.emit(.externalChange)
        await waitUntil { !reloadProposals(in: harness.events).isEmpty }
        let proposal = try XCTUnwrap(reloadProposals(in: harness.events).first)
        harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .deferred)
        XCTAssertEqual(handle.session.text, "clean")
        XCTAssertFalse(handle.session.isDirty)
        harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .refused(.sourceChanged))
        XCTAssertEqual(handle.session.text, "clean")
    }

    func testDirtyConflictFencesWritesAndAutosaveDoesNotTouchTheOriginal() async throws {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        let handle = try await harness.openNote(text: "base")
        handle.session.replaceText("dirty local")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("someone else".utf8))
        port.emit(.externalChange)
        await waitUntil {
            if case .conflict = harness.store.state(for: handle.identity) {
                return true
            }
            return false
        }
        let writesBefore = port.written.count
        handle.session.replaceText("still local")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(port.written.count, writesBefore)
        XCTAssertEqual(handle.session.text, "still local")
        let saving = Task { try await harness.store.save(handle.identity) }
        do {
            _ = try await saving.value
            XCTFail("conflict must refuse the original-file save")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .conflict)
        }
        XCTAssertEqual(port.written.count, writesBefore)
    }

    func testConflictEventRequiresDurableRecovery() async throws {
        let recovery = ScriptedRecovery()
        await recovery.setFailNext(true)
        let harness = DocumentIOHarness(recovery: recovery)
        let handle = try await harness.openNote(text: "keep me")
        handle.session.replaceText("dirty")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        port.emit(.externalChange)
        await waitUntil { harness.events.contains { event in
            if case let .failed(_, _, reason) = event {
                return reason == .recoveryFailed
            }
            return false
        } }
        if case .conflict = harness.store.state(for: handle.identity) {
            XCTFail("conflict must not publish before recovery is durable")
        }
        XCTAssertFalse(harness.events.contains { event in
            if case .recoveryPersisted = event {
                return true
            }
            return false
        })
        XCTAssertEqual(handle.session.text, "dirty")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testOwnSavedBytesAreNotAnExternalConflict() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "saved")
        handle.session.replaceText("saved plus")
        let port = try XCTUnwrap(harness.port(for: handle))
        port.blocksSaves = true
        let entered = expectation(description: "save")
        port.onSaveEntered = { entered.fulfill() }
        let saving = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        port.releaseOne()
        _ = try await saving.value
        await harness.coordinator.setBytes(Data("saved plus".utf8))
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.completedReads() == 1 }
        if case .conflict = harness.store.state(for: handle.identity) {
            XCTFail("bytes written by this store are not an external conflict")
        }
        XCTAssertTrue(reloadProposals(in: harness.events).isEmpty)
        XCTAssertFalse(handle.session.isDirty)
    }

    func testResolveReloadRereadsAndKeepsRecovery() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "local")
        handle.session.replaceText("dirty")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("first remote".utf8))
        port.emit(.externalChange)
        await waitUntil {
            if case .conflict = harness.store.state(for: handle.identity) {
                return true
            }
            return false
        }
        let recordsBefore = await harness.recovery.list()
        await harness.coordinator.setBytes(Data("latest remote".utf8))
        try await harness.store.resolveExternal(handle.identity, choice: .reload)
        let proposal = try XCTUnwrap(reloadProposals(in: harness.events).last)
        XCTAssertEqual(proposal.text, "latest remote")
        XCTAssertEqual(handle.session.text, "dirty")
        let recordsAfter = await harness.recovery.list()
        XCTAssertEqual(recordsAfter.records.count, recordsBefore.records.count)
        XCTAssertGreaterThan(recordsAfter.records.count, 0)
    }

    func testSaveCopyRefusesExistingDestinationAndLeavesOriginal() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "original")
        handle.session.replaceText("dirty copy")
        let version = handle.session.version
        let destination = harness.location(relativePath: "Copy.md", generation: 1, resourceID: nil)
        let lease = harness.directoryLease(generation: 1)
        await harness.coordinator.seedExisting(Data(destination.relativePath.utf8))
        do {
            _ = try await harness.store.saveCopy(handle.identity, destination: destination, lease: lease)
            XCTFail("existing destination must be refused")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.alreadyExists))
        }
        XCTAssertEqual(handle.session.text, "dirty copy")
        XCTAssertEqual(handle.session.version, version)
        XCTAssertTrue(handle.session.isDirty)
        let created = await harness.coordinator.createdLeaves()
        XCTAssertTrue(created.isEmpty)

        await harness.coordinator.removeExisting(Data(destination.relativePath.utf8))
        let acknowledgement = try await harness.store.saveCopy(handle.identity, destination: destination, lease: lease)
        XCTAssertEqual(acknowledgement.savedText, "dirty copy")
        XCTAssertEqual(acknowledgement.location.relativePath, "Copy.md")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(handle.session.text, "dirty copy")
    }
}

private func reloadProposals(in events: [IOSDocumentEvent]) -> [IOSDocumentReloadProposal] {
    events.compactMap { event in
        if case let .externalReloadRequested(proposal) = event {
            return proposal
        }
        return nil
    }
}


