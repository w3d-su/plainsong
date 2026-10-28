@testable import PlainsongIOSM0
import UIKit
import XCTest

final class BackgroundTests: XCTestCase {
    @MainActor
    func testActiveDelayedSaveKeepsBackgroundAssertionUntilCapturedWriteCompletes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = BackgroundAssertionProbe()
        let session = makeSession(assertion)
        let url = try await open(session, in: directory)
        edit("captured N", in: session)
        session.delaySave = true
        let saved = expectation(description: "active capture completed")
        session.save { success in
            XCTAssertTrue(success)
            saved.fulfill()
        }
        XCTAssertTrue(session.saving)
        session.background()
        XCTAssertEqual(assertion.started.count, 1)
        XCTAssertTrue(assertion.ended.isEmpty)
        session.background()
        XCTAssertEqual(assertion.started.count, 1)
        edit("newer N+1 中文", in: session)
        await fulfillment(of: [saved], timeout: 6)
        XCTAssertEqual(assertion.ended, assertion.started)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "captured N")
        XCTAssertEqual(session.editor.textView.text, "newer N+1 中文")
        XCTAssertTrue(session.dirty)
        try await close(session)
    }

    @MainActor
    func testActiveSaveExpirationRetainsRecoveryAndEndsAssertionOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = BackgroundAssertionProbe()
        let session = makeSession(assertion)
        _ = try await open(session, in: directory)
        edit("captured N", in: session)
        session.delaySave = true
        let saved = expectation(description: "capture returns after expiration")
        session.save { success in
            XCTAssertTrue(success)
            saved.fulfill()
        }
        session.background()
        XCTAssertTrue(assertion.ended.isEmpty)
        edit("live N+1", in: session)
        let expiration = try XCTUnwrap(assertion.expiration)
        expiration()
        XCTAssertEqual(assertion.ended, assertion.started)
        XCTAssertTrue(session.probe.events.contains { $0.event == "background-expired" })
        let recovery = try RecoveryStore.applicationStore().readAll().first {
            $0.documentID == session.editor.documentID
        }
        XCTAssertEqual(recovery?.source, "live N+1")
        XCTAssertEqual(recovery?.reason, "background-expiration")
        await fulfillment(of: [saved], timeout: 6)
        expiration()
        XCTAssertEqual(assertion.ended.count, 1)
        try await close(session)
    }

    @MainActor
    func testRefusedActiveSaveEndsBackgroundAssertionAfterFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = BackgroundAssertionProbe()
        let session = makeSession(assertion)
        let url = try await open(session, in: directory)
        edit("captured draft", in: session)
        session.delaySave = true
        let saved = expectation(description: "failed capture completed")
        session.save { success in
            XCTAssertFalse(success)
            saved.fulfill()
        }
        session.background()
        XCTAssertTrue(assertion.ended.isEmpty)
        session.externalChange(url: url, completion: nil)
        await fulfillment(of: [saved], timeout: 6)
        XCTAssertEqual(assertion.ended, assertion.started)
        XCTAssertTrue(session.dirty)
        XCTAssertTrue(session.probe.events.contains { $0.event == "save-refused-before-write" })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "baseline")
        let recovery = try RecoveryStore.applicationStore().readAll().first {
            $0.documentID == session.editor.documentID
        }
        XCTAssertEqual(recovery?.source, "captured draft")
        XCTAssertEqual(recovery?.reason, "external-conflict")
        // The conflict test intentionally discards only this recovered public
        // fixture after proving that the original file was never overwritten.
        let document = try XCTUnwrap(session.document)
        document.updateChangeCount(.cleared)
        document.requestAutosave = { $0(true) }
        let closed: Bool = await withCheckedContinuation { continuation in
            document.close { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closed)
    }

    @MainActor
    func testRecoveryFailureKeepsBackgroundAssertionForActiveCapture() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = BackgroundAssertionProbe()
        var recoveryFails = false
        let session = makeSession(assertion, persistRecovery: { snapshot in
            if recoveryFails {
                throw CocoaError(.fileWriteUnknown)
            }
            try RecoveryStore.applicationStore().persist(snapshot)
        })
        let url = try await open(session, in: directory)
        edit("captured despite later recovery failure", in: session)
        session.delaySave = true
        let saved = expectation(description: "already-captured save completed")
        session.save { success in
            XCTAssertTrue(success)
            saved.fulfill()
        }
        XCTAssertTrue(session.saving)
        recoveryFails = true
        session.background()
        XCTAssertTrue(session.probe.events.contains { $0.event == "recovery-failed" })
        XCTAssertEqual(assertion.started.count, 1)
        XCTAssertTrue(assertion.ended.isEmpty)
        await fulfillment(of: [saved], timeout: 6)
        XCTAssertEqual(assertion.ended, assertion.started)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "captured despite later recovery failure")
        XCTAssertFalse(session.dirty)
        try await close(session)
    }

    @MainActor
    func testNoWriterEndsBackgroundAssertionImmediately() async throws {
        let assertion = BackgroundAssertionProbe()
        let session = makeSession(assertion)
        session.background()
        XCTAssertEqual(assertion.ended, assertion.started)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await open(session, in: directory)
        session.background()
        XCTAssertEqual(assertion.ended, assertion.started)
        XCTAssertFalse(session.saving)
        try await close(session)
    }

    @MainActor
    private func makeSession(_ assertion: BackgroundAssertionProbe,
                             persistRecovery: @escaping (RecoveryEnvelope) throws -> Void = {
                                 try RecoveryStore.applicationStore().persist($0)
                             }) -> DocumentSession
    {
        DocumentSession(editor: SourceEditor(), probe: Probe(),
                        beginBackgroundTask: { assertion.begin(expiration: $0) },
                        endBackgroundTask: { assertion.end($0) }, persistRecovery: persistRecovery)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func open(_ session: DocumentSession, in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("background.md")
        try Data("baseline".utf8).write(to: url)
        try await session.open(url: url, grant: AccessGrant(root: url, scope: .singleFile, appPrivate: true))
        XCTAssertNotNil(session.document)
        return url
    }

    @MainActor
    private func edit(_ source: String, in session: DocumentSession) {
        session.editor.textView.text = source
        session.editor.textViewDidChange(session.editor.textView)
    }

    @MainActor
    private func close(_ session: DocumentSession) async throws {
        session.delaySave = false
        if session.dirty {
            let saved: Bool = await withCheckedContinuation { continuation in
                session.save { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(saved)
        }
        let document = try XCTUnwrap(session.document)
        let closed: Bool = await withCheckedContinuation { continuation in
            document.close { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closed)
    }
}

@MainActor
private final class BackgroundAssertionProbe {
    var started: [UIBackgroundTaskIdentifier] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var expiration: (@MainActor @Sendable () -> Void)?

    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        let identifier = UIBackgroundTaskIdentifier(rawValue: started.count + 1)
        started.append(identifier)
        self.expiration = expiration
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }
}
