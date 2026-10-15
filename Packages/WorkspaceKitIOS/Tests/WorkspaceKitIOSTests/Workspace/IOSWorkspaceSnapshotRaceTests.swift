import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceSnapshotRaceTests: XCTestCase {
    func testLateRefreshAfterANewGrantDoesNotPublishIntoTheNewRoot() async throws {
        let harness = AccessHarness()
        let original = try await harness.openDirectory("/tmp/plainsong-lane06/FolderA")
        harness.files.parkLists = true
        let refresh = Task { try await harness.service.refresh(original) }
        await waitUntil { harness.files.parkedListCount == 1 }
        let replacement = try await harness.openDirectory("/tmp/plainsong-lane06/FolderB")
        harness.files.resumeList(.success([
            item(root: original.rootURL, relativePath: "late.md"),
        ]))
        let snapshot = try await refresh.value
        XCTAssertEqual(snapshot.workspaceID, original.workspaceID)
        XCTAssertEqual(snapshot.entries.map(\.location.relativePath), ["late.md"])
        XCTAssertNil(harness.service.snapshot(for: replacement.workspaceID))
    }

    func testSupersededRefreshDoesNotReplaceTheCurrentTree() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.listResult = .success([item(root: grant.rootURL, relativePath: "kept.md")])
        let first = try await harness.service.refresh(grant)
        XCTAssertEqual(first.entries.map(\.location.relativePath), ["kept.md"])
        harness.files.parkLists = true
        let stale = Task { try await harness.service.refresh(grant) }
        await waitUntil { harness.files.parkedListCount == 1 }
        let current = Task { try await harness.service.refresh(grant) }
        await waitUntil { harness.files.parkedListCount == 2 }
        harness.files.resumeList(.success([item(root: grant.rootURL, relativePath: "stale.md")]), at: 0)
        harness.files.resumeList(.success([item(root: grant.rootURL, relativePath: "current.md")]), at: 0)
        do {
            _ = try await stale.value
            XCTFail("stale refresh published")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .grantChanged)
        }
        let published = try await current.value
        XCTAssertEqual(published.entries.map(\.location.relativePath), ["current.md"])
        XCTAssertEqual(harness.service.snapshot(for: grant.workspaceID)?.requestID, published.requestID)
    }

    func testOfflineRefreshKeepsThePreviousTree() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        var seen: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { seen.append($0) }
        harness.files.listResult = .success([
            item(root: grant.rootURL, relativePath: "Note.md", availability: .available(canWrite: false)),
            item(root: grant.rootURL, relativePath: "photo.png", availability: .downloading),
            item(root: grant.rootURL, relativePath: "draft.md", availability: .offline),
        ])
        let snapshot = try await harness.service.refresh(grant)
        XCTAssertEqual(snapshot.entries.count, 3)
        harness.files.listResult = .failure(IOSWorkspaceFailure.offline)
        do {
            _ = try await harness.service.refresh(grant)
            XCTFail("offline refresh replaced the tree")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .offline)
        }
        XCTAssertEqual(harness.service.snapshot(for: grant.workspaceID)?.entries.count, 3)
        XCTAssertTrue(seen.contains { event in
            if case let .unavailable(_, reason) = event {
                return reason == .offline
            }
            return false
        })
    }

    func testUnicodeSpellingsStayDistinctWhenProviderIdentityCollides() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let nfc = "caf\u{00E9}.md"
        let nfd = "cafe\u{0301}.md"
        let identity = Data("same-provider".utf8)
        harness.files.listResult = .success([
            item(root: grant.rootURL, relativePath: nfc, identity: identity),
            item(root: grant.rootURL, relativePath: nfd, identity: identity),
        ])
        let snapshot = try await harness.service.refresh(grant)
        let paths = snapshot.entries.map(\.location.relativePath)
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(Data(nfc.utf8), Data(nfd.utf8))
        XCTAssertTrue(paths.contains(nfc))
        XCTAssertTrue(paths.contains(nfd))
    }

    func testExternalReportDoesNotCoordinate() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        var seen: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { seen.append($0) }
        let before = harness.files.ioCalls
        harness.service.report(.changed(relativePath: "Note.md"))
        harness.service.report(.deleted(relativePath: "Note.md"))
        harness.service.report(.moved(from: "Note.md", to: "Renamed.md"))
        harness.service.report(.offlineRoot)
        XCTAssertEqual(harness.files.ioCalls, before)
        XCTAssertEqual(seen.filter {
            if case .resourceChanged = $0 {
                return true
            }; return false
        }.count, 4)
        XCTAssertTrue(seen.contains { event in
            if case let .unavailable(workspaceID, reason) = event {
                return workspaceID == grant.workspaceID && reason == .offline
            }
            return false
        })
    }

    func testEmptyFileReadIsSuccess() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.readResult = .success(Data())
        let value = try await harness.service.read(
            harness.location(grant: grant, relativePath: "Note.md"),
            lease: harness.service.acquireLease(for: grant),
            operationID: UUID(),
            maximumByteCount: 16
        )
        XCTAssertTrue(value.data.isEmpty)
    }

    func testReadFailureDoesNotReturnEmptyBytes() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.readResult = .failure(IOSWorkspaceFailure.permissionDenied)
        let lease = try harness.service.acquireLease(for: grant)
        do {
            let value = try await harness.service.read(
                harness.location(grant: grant, relativePath: "Note.md"),
                lease: lease,
                operationID: UUID(),
                maximumByteCount: 16
            )
            XCTFail("failed read returned \(value.data.count) bytes")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .permissionDenied)
        }
    }

    private func item(
        root: URL,
        relativePath: String,
        identity: Data? = nil,
        availability: IOSFileAvailability = .available(canWrite: true)
    ) -> IOSWorkspaceFileItem {
        IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: IOSWorkspacePathAuthority.fileURL(
                path: IOSWorkspacePathAuthority.joined(root: root, relativePath: relativePath)
            ),
            isDirectory: false,
            isSymlink: false,
            fileSize: 4,
            availability: availability,
            providerIdentity: identity,
            bytes: nil
        )
    }
}
