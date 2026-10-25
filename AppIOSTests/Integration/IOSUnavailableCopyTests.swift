import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSUnavailableCopyTests: XCTestCase {
    func testDirtyUnavailableSourceCanBeCopiedWithoutClosingOrReauthorizingTheOrigin() async throws {
        for revoke in [false, true] {
            let fixture = IOSConflictCopyFixture()
            defer { fixture.stop() }
            let handle = try await fixture.openConflict()
            fixture.documents.base.states[handle.identity] = .unavailable(
                accessGeneration: handle.location.accessGeneration, reason: .access(.offline)
            )
            fixture.controller.updateEditorAccess()
            if revoke {
                _ = fixture.workspace.invalidate(handle.location.workspaceID)
            }
            let generation = fixture.editor.snapshot.accessGeneration
            let source = handle.session.text
            let version = handle.session.version
            let request = try fixture.prepare(filename: "Unavailable Copy.md")
            let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))

            let outcome = await task.value

            XCTAssertEqual(outcome, .saved(filename: request.filename))
            XCTAssertEqual(fixture.documents.createdCopies.first?.1, source)
            XCTAssertTrue(fixture.controller.handle?.session === handle.session)
            XCTAssertEqual(handle.session.text, source)
            XCTAssertEqual(handle.session.version, version)
            XCTAssertTrue(handle.session.isDirty)
            XCTAssertTrue(fixture.documents.base.closed.isEmpty)
            XCTAssertTrue(fixture.documents.base.saved.isEmpty)
            XCTAssertFalse(fixture.editor.snapshot.canWrite)
            XCTAssertEqual(fixture.editor.snapshot.accessGeneration, generation)
            XCTAssertEqual(fixture.controller.grantIsCurrent, !revoke)
            XCTAssertEqual(fixture.workspace.base.selected.count, 2)
            guard case .unavailable = fixture.documents.state(for: handle.identity) else {
                return XCTFail("Copy must not clear unavailable status")
            }
            fixture.copy.nameSheetDidDismiss(request.draftID)
            XCTAssertTrue(fixture.copy.notice?.message.contains("After restarting") == true)
        }
    }

    func testRevocationDuringUnavailableCopyRefusesAfterTheOwnedProviderDrains() async throws {
        for duringWrite in [false, true] {
            let fixture = IOSConflictCopyFixture()
            defer { fixture.stop() }
            let handle = try await fixture.openConflict()
            fixture.documents.base.states[handle.identity] = .unavailable(
                accessGeneration: handle.location.accessGeneration, reason: .access(.offline)
            )
            fixture.controller.updateEditorAccess()
            let request = try fixture.prepare()
            let latch = IOSSceneControllerLatch()
            defer { latch.release() }
            if duringWrite {
                fixture.documents.copyLatch = latch
            } else {
                fixture.workspace.openLatch = latch
            }
            let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                if duringWrite ? !fixture.documents.copyRequests.isEmpty : fixture.workspace.destinationGrant != nil {
                    break
                }
                await Task.yield()
            }
            XCTAssertNotNil(fixture.workspace.destinationGrant)
            if duringWrite {
                XCTAssertEqual(fixture.documents.copyRequests.count, 1)
                XCTAssertFalse(try XCTUnwrap(fixture.documents.copyRequests.first?.lease).isReleased)
                XCTAssertTrue(fixture.controller.transitioning)
            }
            _ = fixture.workspace.invalidate(handle.location.workspaceID)
            XCTAssertTrue(fixture.controller.handle?.session === handle.session)
            if duringWrite {
                XCTAssertFalse(try XCTUnwrap(fixture.documents.copyRequests.first?.lease).isReleased)
            }
            latch.release()
            let outcome = await task.value
            XCTAssertEqual(outcome, .refused(.originChanged, copyMayExist: duringWrite))
            XCTAssertEqual(fixture.documents.copyRequests.count, duringWrite ? 1 : 0)
            XCTAssertTrue(handle.session.isDirty)
            XCTAssertTrue(fixture.documents.base.closed.isEmpty)
            XCTAssertTrue(fixture.documents.base.saved.isEmpty)
            XCTAssertFalse(fixture.controller.grantIsCurrent)
            XCTAssertFalse(fixture.controller.transitioning)
            XCTAssertTrue(fixture.workspace.base.leases.filter {
                $0.grant.workspaceID != handle.location.workspaceID
            }.allSatisfy(\.isReleased))
        }
    }

    func testUnavailableSourceStateChangeRetiresTheDestinationPicker() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        fixture.documents.base.states[handle.identity] = .unavailable(
            accessGeneration: handle.location.accessGeneration, reason: .access(.offline)
        )
        fixture.controller.updateEditorAccess()
        let request = try fixture.prepare()
        fixture.documents.base.states[handle.identity] = .unavailable(
            accessGeneration: handle.location.accessGeneration, reason: .access(.notFound)
        )
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.originChanged, copyMayExist: false))
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertEqual(fixture.workspace.base.selected.count, 1)
    }
}
