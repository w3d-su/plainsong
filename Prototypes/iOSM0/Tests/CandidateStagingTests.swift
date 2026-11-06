@testable import PlainsongIOSM0
import UIKit
import XCTest

final class CandidateStagingTests: XCTestCase {
    @MainActor
    func testCandidateRevertDuringReplacementCloseRetainsOriginalAndRetryLoadsFreshBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("original source".utf8).write(to: first)
        try Data("candidate before external edit".utf8).write(to: second)
        let gate = CandidateCloseGate()
        var candidate: SpikeDocument?
        let session = DocumentSession(editor: SourceEditor(), probe: Probe(), makeDocument: { url in
            let document = SpikeDocument(fileURL: url)
            if url == second {
                candidate = document
            }
            return document
        }, closeForReplacement: { await gate.close($0) })
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        let original = try XCTUnwrap(session.document)
        let identity = session.editor.documentID
        let revision = session.editor.revision
        session.editor.textView.selectedRange = NSRange(location: 3, length: 4)
        let selection = session.editor.textView.selectedRange
        let replacement = Task { @MainActor in
            try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let staged = try XCTUnwrap(candidate)
        try Data("candidate after external edit".utf8).write(to: second)
        let reverted: Bool = await withCheckedContinuation { continuation in
            staged.revert(toContentsOf: second) { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(reverted)
        await gate.finish()
        try await replacement.value
        XCTAssertTrue(session.document === original)
        XCTAssertEqual(session.editor.documentID, identity)
        XCTAssertEqual(session.editor.revision, revision)
        XCTAssertEqual(session.editor.textView.text, "original source")
        XCTAssertEqual(session.editor.textView.selectedRange, selection)
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(original.documentState.contains(.closed))
        XCTAssertTrue(staged.documentState.contains(.closed))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original source")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "candidate after external edit")
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertFalse(session.document === original)
        XCTAssertEqual(session.editor.textView.text, "candidate after external edit")
        XCTAssertFalse(session.dirty)
        XCTAssertTrue(session.editor.textView.isEditable)
        try await close(session)
    }

    @MainActor
    func testCandidateAvailabilityLossDuringReplacementCloseRefusesEvenAfterEnable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("original".utf8).write(to: first)
        try Data("candidate".utf8).write(to: second)
        let gate = CandidateCloseGate()
        var candidate: SpikeDocument?
        let session = DocumentSession(editor: SourceEditor(), probe: Probe(), makeDocument: { url in
            let document = SpikeDocument(fileURL: url)
            if url == second {
                candidate = document
            }
            return document
        }, closeForReplacement: { await gate.close($0) })
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        let original = try XCTUnwrap(session.document)
        let replacement = Task { @MainActor in
            try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let staged = try XCTUnwrap(candidate)
        let disabled = expectation(description: "candidate disable delivered")
        let enabled = expectation(description: "candidate enable delivered")
        let observedAvailability = staged.editingAvailability
        staged.editingAvailability = { value in
            observedAvailability?(value)
            if value {
                enabled.fulfill()
            } else {
                disabled.fulfill()
            }
        }
        staged.disableEditing()
        await fulfillment(of: [disabled], timeout: 5)
        staged.enableEditing()
        await fulfillment(of: [enabled], timeout: 5)
        staged.editingAvailability = observedAvailability
        await gate.finish()
        try await replacement.value
        XCTAssertTrue(session.document === original)
        XCTAssertEqual(session.editor.textView.text, "original")
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(original.documentState.contains(.closed))
        XCTAssertTrue(staged.documentState.contains(.closed))
        XCTAssertFalse(session.dirty)
        try await close(session)
    }

    @MainActor
    func testChangedCandidateFailedDisposalKeepsGrantUntilCloseRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("original".utf8).write(to: first)
        try Data("candidate".utf8).write(to: second)
        let gate = CandidateCloseGate()
        var candidate: SpikeDocument?
        var discardFails = true
        let session = DocumentSession(editor: SourceEditor(), probe: Probe(), makeDocument: { url in
            let document = SpikeDocument(fileURL: url)
            if url == second {
                candidate = document
            }
            return document
        }, closeForReplacement: { await gate.close($0) }, closeDiscardedCandidate: { document in
            guard !discardFails else { return false }
            return await withCheckedContinuation { continuation in
                document.close { continuation.resume(returning: $0) }
            }
        })
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        let original = try XCTUnwrap(session.document)
        var selectedGrant: AccessGrant? = try AccessGrant(root: second, scope: .singleFile, appPrivate: true)
        weak var retainedGrant = selectedGrant
        var replacement: Task<Void, Never>? = try beginOpen(session, url: second, grant: XCTUnwrap(selectedGrant))
        await fulfillment(of: [gate.entered], timeout: 5)
        let staged = try XCTUnwrap(candidate)
        let reverted: Bool = await withCheckedContinuation { continuation in
            staged.revert(toContentsOf: second) { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(reverted)
        await gate.finish()
        await replacement?.value
        replacement = nil
        selectedGrant = nil
        XCTAssertNotNil(retainedGrant)
        XCTAssertTrue(session.document === original)
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(staged.documentState.contains(.closed))
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertTrue(session.message.contains("Candidate close is still pending"))
        XCTAssertTrue(session.document === original)
        discardFails = false
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertNil(retainedGrant)
        XCTAssertTrue(staged.documentState.contains(.closed))
        XCTAssertEqual(session.editor.textView.text, "candidate")
        XCTAssertFalse(session.dirty)
        try await close(session)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func beginOpen(_ session: DocumentSession, url: URL, grant: AccessGrant) -> Task<Void, Never> {
        Task { @MainActor in await session.open(url: url, grant: grant) }
    }

    @MainActor
    private func close(_ session: DocumentSession) async throws {
        let document = try XCTUnwrap(session.document)
        let closed: Bool = await withCheckedContinuation { continuation in
            document.close { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closed)
    }
}

@MainActor
private final class CandidateCloseGate {
    let entered = XCTestExpectation(description: "previous close is suspended")
    private var held = false
    private var document: SpikeDocument?
    private var continuation: CheckedContinuation<Bool, Never>?

    func close(_ document: SpikeDocument) async -> Bool {
        if held {
            return await withCheckedContinuation { continuation in
                document.close { continuation.resume(returning: $0) }
            }
        }
        held = true
        self.document = document
        entered.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() async {
        guard let document, let continuation else { return }
        let closed: Bool = await withCheckedContinuation { continuation in
            document.close { continuation.resume(returning: $0) }
        }
        self.continuation = nil
        self.document = nil
        continuation.resume(returning: closed)
    }
}
