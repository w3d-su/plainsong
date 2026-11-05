@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
final class WindowWriterAdoptionAppTests: SharedRootAppTestCase {
    func testWarmAdoptionRevokesTheOldWriterBeforeTheNewInstallationExists() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let oldBinding = primary.editorDocumentBinding(for: session)
        let old = installation(oldBinding)
        oldBinding.onLifecycle(.installed(old))
        try primary.activateFileSession(url: root.appendingPathComponent("b.md"))

        try second.activateFileSession(url: root.appendingPathComponent("a.md"))

        XCTAssertTrue(second.shownSession === session)
        XCTAssertNil(primary.editorWriterInstallations[ObjectIdentifier(session)])
        XCTAssertEqual(
            oldBinding.sourceContract.publish(publication(old, session: session, text: "stale writer")),
            .rejected(snapshot(session))
        )
        XCTAssertEqual(
            oldBinding.sourceContract.writer(.activate(old, from: snapshot(session))),
            .rejected(snapshot(session))
        )
        XCTAssertEqual(session.text, "alpha text")
    }

    func testDelayedWriterReleaseAndInstallationRevocationCannotRevokeTheAdoptedWriter() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let oldBinding = primary.editorDocumentBinding(for: session)
        let old = installation(oldBinding)
        oldBinding.onLifecycle(.installed(old))
        try primary.activateFileSession(url: root.appendingPathComponent("b.md"))
        try second.activateFileSession(url: root.appendingPathComponent("a.md"))
        let newBinding = second.editorDocumentBinding(for: session)
        let new = installation(newBinding)
        newBinding.onLifecycle(.installed(new))
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], new)
        XCTAssertEqual(primary.liveEditorDocumentBindingInstallations(for: session).count, 2)

        XCTAssertEqual(oldBinding.sourceContract.writer(.release(old)), .releaseRejected)
        oldBinding.onLifecycle(.revoked(old))

        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], new)
        XCTAssertEqual(primary.liveEditorDocumentBindingInstallations(for: session), [new])
        XCTAssertEqual(
            newBinding.sourceContract.publish(publication(new, session: session, text: "new writer")),
            .accepted(
                EditorDocumentSourceSnapshot(source: "new writer", revision: session.version),
                sourceWasReconciled: false
            )
        )
        XCTAssertEqual(session.text, "new writer")
    }

    func testLeavingTheAdoptingWindowRestoresTheWriterStillShown() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let oldBinding = primary.editorDocumentBinding(for: session)
        let old = installation(oldBinding)
        oldBinding.onLifecycle(.installed(old))
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], old)

        second.setCurrentDocument(session, requestingEditorFocus: false)
        XCTAssertTrue(primary.supersededEditorWriterInstallations.contains(old))
        let newBinding = second.editorDocumentBinding(for: session)
        let adopted = installation(newBinding)
        newBinding.onLifecycle(.installed(adopted))
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], adopted)

        second.setCurrentDocument(DocumentSession(), requestingEditorFocus: false)
        XCTAssertEqual(newBinding.sourceContract.writer(.release(adopted)), .released)
        XCTAssertNil(primary.editorWriterInstallations[ObjectIdentifier(session)])
        XCTAssertEqual(
            oldBinding.sourceContract.writer(.activate(old, from: snapshot(session))),
            .rejected(snapshot(session))
        )
        newBinding.onLifecycle(.revoked(adopted))

        XCTAssertFalse(primary.supersededEditorWriterInstallations.contains(old))
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], old)
        XCTAssertEqual(
            oldBinding.sourceContract.publish(publication(old, session: session, text: "still shown")),
            .accepted(
                EditorDocumentSourceSnapshot(source: "still shown", revision: session.version),
                sourceWasReconciled: false
            )
        )
        XCTAssertEqual(session.text, "still shown")
    }

    func testStaleAdopterKeepsTheEarlierWindowSupersededUntilItsSynchronizedRetry() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let oldBinding = primary.editorDocumentBinding(for: session)
        let old = installation(oldBinding)
        oldBinding.onLifecycle(.installed(old))
        second.setCurrentDocument(session, requestingEditorFocus: false)
        let binding = second.editorDocumentBinding(for: session)
        let adopted = installation(binding)
        binding.onLifecycle(.installed(adopted))
        let stale = snapshot(session)
        _ = binding.sourceContract.publish(publication(adopted, session: session, text: "edited"))
        let current = snapshot(session)
        XCTAssertNotEqual(current.revision, stale.revision)

        XCTAssertEqual(binding.sourceContract.writer(.activate(adopted, from: stale)), .synchronize(current))
        XCTAssertNil(primary.editorWriterInstallations[ObjectIdentifier(session)])
        XCTAssertEqual(oldBinding.sourceContract.writer(.activate(old, from: current)), .rejected(current))
        XCTAssertEqual(binding.sourceContract.writer(.activate(adopted, from: current)), .activated(current))
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], adopted)
    }

    func testLateInstallFromPreviousWindowCannotAcquireWriterOnEitherSideOfAdopterInstall() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let oldBinding = primary.editorDocumentBinding(for: session)
        try primary.activateFileSession(url: root.appendingPathComponent("b.md"))
        second.setCurrentDocument(session, requestingEditorFocus: false)
        let early = installation(oldBinding)
        oldBinding.onLifecycle(.installed(early))
        XCTAssertEqual(
            oldBinding.sourceContract.writer(.activate(early, from: snapshot(session))),
            .rejected(snapshot(session))
        )

        let binding = second.editorDocumentBinding(for: session)
        let adopted = installation(binding)
        binding.onLifecycle(.installed(adopted))
        let late = installation(oldBinding)
        oldBinding.onLifecycle(.installed(late))
        XCTAssertEqual(
            oldBinding.sourceContract.writer(.activate(late, from: snapshot(session))),
            .rejected(snapshot(session))
        )
        XCTAssertEqual(primary.editorWriterInstallations[ObjectIdentifier(session)], adopted)
    }

    private func installation(_ binding: AppEditorDocumentBinding) -> EditorDocumentBindingInstallation {
        EditorDocumentBindingInstallation(bindingID: binding.id, installationID: EditorDocumentBindingInstallationID())
    }

    private func snapshot(_ session: DocumentSession) -> EditorDocumentSourceSnapshot {
        EditorDocumentSourceSnapshot(source: session.text, revision: session.version)
    }

    private func publication(
        _ installation: EditorDocumentBindingInstallation, session: DocumentSession, text: String
    ) -> EditorDocumentSourcePublication {
        EditorDocumentSourcePublication(installation: installation, base: snapshot(session), source: text)
    }
}
