import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

final class IOSDocumentReloadRelayTests: XCTestCase {
    @MainActor
    func testInstallAndAcknowledgementFinishSynchronouslyWithoutReentrantInstallation() {
        let fixture = IOSReloadRelayFixture()
        var events: [String] = []
        fixture.editor.onEvent = { events.append($0) }
        fixture.store.onEvent = { events.append($0) }
        let proposal = fixture.proposal()

        fixture.store.emit(.externalReloadRequested(proposal))
        events.append("returned")

        XCTAssertEqual(events, ["install", "ack", "returned"])
        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.store.acknowledgements.map(\.0), [proposal.operationID])
        XCTAssertEqual(fixture.store.acknowledgements.first?.1, .installed(fixture.editor.snapshot.revision))
        XCTAssertEqual(fixture.editor.binding.session.text, "external")
    }

    @MainActor
    func testMarkedTextDefersUntilALaterUnmarkedSnapshot() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        let proposal = fixture.proposal()
        fixture.store.emit(.externalReloadRequested(proposal))
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.binding.session.text, "original")
        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.store.acknowledgements.map(\.1), [.deferred])

        fixture.editor.hasMarkedText = false
        fixture.editor.emitSnapshot()
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.binding.session.text, "external")
        XCTAssertEqual(fixture.editor.installed.count, 2)
        XCTAssertEqual(fixture.store.acknowledgements.map(\.1), [
            .deferred, .installed(fixture.editor.snapshot.revision),
        ])
    }

    @MainActor
    func testBusyDeferralDoesNotSpinAndRetriesOnANewEditorEvent() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.isBusy = true
        fixture.store.onAcknowledge = { _, _ in fixture.editor.emitSnapshot() }
        fixture.store.emit(.externalReloadRequested(fixture.proposal()))

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.store.acknowledgements.map(\.1), [.deferred])

        fixture.editor.isBusy = false
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 2)
        XCTAssertEqual(fixture.editor.binding.session.text, "external")
    }

    @MainActor
    func testNewProposalSupersedesDeferredReadInsteadOfReplayingOldBytes() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        let old = fixture.proposal(text: "old")
        let latest = fixture.proposal(text: "latest")
        fixture.store.emit(.externalReloadRequested(old))
        fixture.store.emit(.externalReloadRequested(latest))
        fixture.editor.hasMarkedText = false
        fixture.editor.emitSnapshot()
        fixture.store.emit(.externalReloadRequested(old))

        XCTAssertEqual(fixture.editor.installed.map(\.text), ["old", "latest", "latest"])
        XCTAssertEqual(fixture.editor.binding.session.text, "latest")
        XCTAssertEqual(fixture.store.acknowledgements.last?.0, latest.operationID)
    }

    @MainActor
    func testNewerSourceRefusesDeferredReadAndRetainsTheDraft() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        fixture.store.emit(.externalReloadRequested(fixture.proposal()))
        fixture.editor.binding.session.replaceTextFromAuthorizedEditor("newer draft")
        fixture.editor.hasMarkedText = false
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.editor.binding.session.text, "newer draft")
        XCTAssertTrue(fixture.editor.binding.session.isDirty)
        XCTAssertEqual(fixture.store.acknowledgements.last?.1, .refused(.sourceChanged))
    }

    @MainActor
    func testAccessChangeRefusesDeferredReadBeforeNativeInstallation() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        fixture.store.emit(.externalReloadRequested(fixture.proposal()))
        fixture.editor.updateAccess(
            for: fixture.editor.binding.identity, bindingID: fixture.editor.binding.bindingID,
            generation: 2, canWrite: false
        )
        fixture.editor.hasMarkedText = false
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.editor.binding.session.text, "original")
        XCTAssertEqual(fixture.store.acknowledgements.last?.1, .refused(.accessChanged))
    }

    @MainActor
    func testSameDocumentNewBindingFencesCancelledCallbacksAndPendingRead() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        let old = fixture.proposal()
        fixture.store.emit(.externalReloadRequested(old))
        let staleStoreCallback = fixture.store.observations[0].1
        let staleEditorCallback = fixture.editor.observations[0].1
        let priorBinding = fixture.editor.binding
        fixture.editor.binding = IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: priorBinding.identity, session: priorBinding.session,
            accessGeneration: priorBinding.accessGeneration, canWrite: true
        )
        fixture.attach()
        fixture.editor.hasMarkedText = false
        staleStoreCallback(.externalReloadRequested(old))
        staleEditorCallback(.snapshotChanged(fixture.editor.snapshot))
        fixture.editor.emitSnapshot()

        XCTAssertTrue(fixture.store.observations[0].0.isCancelled)
        XCTAssertTrue(fixture.editor.observations[0].0.isCancelled)
        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.editor.binding.session.text, "original")
        fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "new binding")))
        XCTAssertEqual(fixture.editor.binding.session.text, "new binding")
    }

    @MainActor
    func testRetiredProposalCannotReplayThroughTheNewObserverAfterSameDocumentRebind() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.hasMarkedText = true
        let old = fixture.proposal(text: "retired external bytes")
        fixture.store.emit(.externalReloadRequested(old))
        let priorBinding = fixture.editor.binding
        fixture.editor.binding = IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: priorBinding.identity, session: priorBinding.session,
            accessGeneration: priorBinding.accessGeneration, canWrite: true
        )
        fixture.attach()
        fixture.editor.hasMarkedText = false
        // Delivery deliberately uses the current observer, rather than an old
        // cancelled closure. Only the operation tombstone can fence this replay.
        fixture.store.emit(.externalReloadRequested(old))
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(fixture.editor.binding.session.text, "original")
        XCTAssertEqual(fixture.store.acknowledgements.map(\.1), [.deferred])
        fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "fresh external bytes")))
        XCTAssertEqual(fixture.editor.binding.session.text, "fresh external bytes")
    }

    @MainActor
    func testReattachingAnAccessGenerationFencesTheOldObserver() {
        let fixture = IOSReloadRelayFixture()
        let old = fixture.proposal()
        let callback = fixture.store.observations[0].1
        fixture.editor.updateAccess(
            for: fixture.editor.binding.identity, bindingID: fixture.editor.binding.bindingID,
            generation: 2, canWrite: true
        )
        fixture.attach()
        callback(.externalReloadRequested(old))
        fixture.store.emit(.externalReloadRequested(old))
        fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "generation two")))

        XCTAssertEqual(fixture.editor.installed.map(\.text), ["generation two"])
    }

    @MainActor
    func testDuplicateAndReentrantAcknowledgementCannotReplayAnInstalledRead() {
        let fixture = IOSReloadRelayFixture()
        let first = fixture.proposal(text: "first")
        fixture.store.onAcknowledge = { operationID, _ in
            guard operationID == first.operationID else { return }
            fixture.store.emit(.externalReloadRequested(first))
            fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "second")))
        }
        fixture.store.emit(.externalReloadRequested(first))
        fixture.store.emit(.externalReloadRequested(first))

        XCTAssertEqual(fixture.editor.installed.map(\.text), ["first", "second"])
        XCTAssertEqual(fixture.store.acknowledgements.count, 2)
        XCTAssertEqual(fixture.editor.binding.session.text, "second")
    }

    @MainActor
    func testProposalArrivingDuringSnapshotCaptureSupersedesTheUninstalledRead() {
        let fixture = IOSReloadRelayFixture()
        let old = fixture.proposal(text: "old")
        let latest = fixture.proposal(text: "latest")
        fixture.editor.onCapture = {
            fixture.editor.onCapture = nil
            fixture.store.emit(.externalReloadRequested(latest))
        }
        fixture.store.emit(.externalReloadRequested(old))

        XCTAssertEqual(fixture.editor.installed.map(\.text), ["latest"])
        XCTAssertEqual(fixture.store.acknowledgements.map(\.0), [latest.operationID])
    }

    @MainActor
    func testDuplicateDuringNativeInstallationCannotReplaceANewerQueuedRead() {
        let fixture = IOSReloadRelayFixture()
        let first = fixture.proposal(text: "first")
        fixture.editor.onInstall = {
            fixture.editor.onInstall = nil
            fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "newer")))
            fixture.store.emit(.externalReloadRequested(first))
        }
        fixture.store.emit(.externalReloadRequested(first))

        XCTAssertEqual(fixture.editor.installed.map(\.text), ["first", "newer"])
        XCTAssertEqual(fixture.store.acknowledgements.count, 2)
        XCTAssertEqual(fixture.editor.binding.session.text, "newer")
    }

    @MainActor
    func testReentrantBindingReplacementCannotAcknowledgeThroughTheNewLifetime() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.onInstall = {
            fixture.editor.onInstall = nil
            let old = fixture.editor.binding
            fixture.editor.binding = IOSSourceEditorDocumentBinding(
                bindingID: UUID(), identity: old.identity, session: old.session,
                accessGeneration: old.accessGeneration, canWrite: true
            )
            fixture.attach()
        }
        fixture.store.emit(.externalReloadRequested(fixture.proposal()))

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertTrue(fixture.store.acknowledgements.isEmpty)
        fixture.store.emit(.externalReloadRequested(fixture.proposal(text: "new lifetime")))
        XCTAssertEqual(fixture.store.acknowledgements.count, 1)
        XCTAssertEqual(fixture.editor.binding.session.text, "new lifetime")
    }

    @MainActor
    func testSaveAcknowledgementNeverInstallsSavedBytesOverNewerSource() {
        let fixture = IOSReloadRelayFixture()
        fixture.editor.binding.session.replaceTextFromAuthorizedEditor("newer source")
        let location = IOSFileLocation(
            workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), accessGeneration: 1,
            relativePath: "public.md", fileURL: URL(fileURLWithPath: "/synthetic/public.md"), resourceID: nil
        )
        fixture.store.emit(.saveCompleted(IOSSaveAcknowledgement(
            operationID: UUID(),
            revision: IOSDocumentRevision(documentID: fixture.editor.binding.identity, version: 0),
            savedText: "old saved source", location: location
        )))

        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertTrue(fixture.store.acknowledgements.isEmpty)
        XCTAssertEqual(fixture.editor.binding.session.text, "newer source")
        XCTAssertTrue(fixture.editor.binding.session.isDirty)
    }

    @MainActor
    func testDetachAndForeignDocumentEventsCannotInstallOrAcknowledge() {
        let fixture = IOSReloadRelayFixture()
        let proposal = fixture.proposal()
        let foreign = IOSDocumentReloadProposal(
            operationID: UUID(), capturedRevision: IOSDocumentRevision(
                documentID: IOSDocumentIdentity(rawValue: UUID()), version: 0
            ), accessGeneration: 1, text: "foreign", fileURL: proposal.fileURL,
            fileKind: .markdown, statistics: TextStatistics(text: "foreign")
        )
        fixture.store.emit(.externalReloadRequested(foreign))
        fixture.relay.detach()
        fixture.store.observations[0].1(.externalReloadRequested(proposal))
        fixture.editor.observations[0].1(.snapshotChanged(fixture.editor.snapshot))

        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertTrue(fixture.store.acknowledgements.isEmpty)
        XCTAssertTrue(fixture.store.observations[0].0.isCancelled)
        XCTAssertTrue(fixture.editor.observations[0].0.isCancelled)
    }

    @MainActor
    func testAttachingTheSameInstallationDoesNotDuplicateObservers() {
        let fixture = IOSReloadRelayFixture()
        fixture.attach()
        fixture.attach()

        XCTAssertEqual(fixture.store.observations.count, 1)
        XCTAssertEqual(fixture.editor.observations.count, 1)
    }
}
