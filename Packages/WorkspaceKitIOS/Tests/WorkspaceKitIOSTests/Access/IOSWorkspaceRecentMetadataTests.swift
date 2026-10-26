import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceRecentMetadataTests: XCTestCase {
    func testProductionUnknownIdentityReopeningFileKeepsOneRecentRecord() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/Note.md")
        harness.files.rootIsDirectory = false
        let first = try await service.open(selectedURL: url, scope: .singleFile)
        let firstID = try XCTUnwrap(service.recentItems().first?.recordID)
        for _ in 0 ..< 3 {
            let next = try await service.open(selectedURL: url, scope: .singleFile)
            XCTAssertNil(service.records[next.workspaceID]?.providerIdentity)
            _ = service.invalidate(next.workspaceID)
        }
        XCTAssertEqual(service.recentItems().count, 1)
        XCTAssertEqual(service.recentItems().first?.recordID, firstID)
        XCTAssertNil(service.recentItems().first?.providerIdentity)
        _ = service.invalidate(first.workspaceID)
    }

    func testUnknownIdentityDifferentFilesAndFoldersStayDistinct() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        for scope in [IOSWorkspaceScope.singleFile, .directory] {
            harness.files.rootIsDirectory = scope == .directory
            for leaf in ["First", "Second", "First"] {
                let path = "/tmp/plainsong-recents/\(scope == .directory ? "Folders" : "Files")/\(leaf)"
                let grant = try await service.open(
                    selectedURL: IOSWorkspacePathAuthority.fileURL(path: path),
                    scope: scope
                )
                _ = service.invalidate(grant.workspaceID)
            }
        }
        XCTAssertEqual(service.recentItems().count, 4)
        XCTAssertEqual(service.recentItems().filter { $0.scope == .singleFile }.count, 2)
        XCTAssertEqual(service.recentItems().filter { $0.scope == .directory }.count, 2)
        XCTAssertTrue(service.recentItems().allSatisfy { $0.providerIdentity == nil })
    }

    func testSamePathAndProviderIdentityDoNotCollapseDifferentScopes() async throws {
        let harness = AccessHarness()
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/ChangedKind")
        harness.identity.identity = Data("provider-id".utf8)
        harness.files.rootIsDirectory = false
        let file = try await harness.service.open(selectedURL: url, scope: .singleFile)
        _ = harness.service.invalidate(file.workspaceID)
        harness.files.rootIsDirectory = true
        let directory = try await harness.service.open(selectedURL: url, scope: .directory)
        _ = harness.service.invalidate(directory.workspaceID)
        XCTAssertEqual(harness.service.recentItems().count, 2)
        XCTAssertEqual(harness.service.recentItems().filter { $0.scope == .singleFile }.count, 1)
        XCTAssertEqual(harness.service.recentItems().filter { $0.scope == .directory }.count, 1)
    }

    func testPrivateMatchingMetadataSurvivesStoreRoundTripAndNewService() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/Note.md")
        harness.files.rootIsDirectory = false
        let first = try await service.open(selectedURL: url, scope: .singleFile)
        _ = service.invalidate(first.workspaceID)
        let old = harness.recents.load()
        try harness.recents.save(JSONDecoder().decode(
            [IOSStoredRecentWorkspace].self,
            from: JSONEncoder().encode(old)
        ))
        let relaunched = productionIdentityService(harness)
        let next = try await relaunched.open(selectedURL: url, scope: .singleFile)
        _ = relaunched.invalidate(next.workspaceID)
        XCTAssertEqual(relaunched.recentItems().count, 1)
        XCTAssertEqual(relaunched.recentItems().first?.recordID, old.first?.recordID)
    }

    func testLegacyBookmarkMetadataDeduplicatesWithoutIssuingAnotherGrant() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/Legacy.md")
        let oldID = UUID()
        let legacy = IOSStoredRecentWorkspace(
            recordID: oldID,
            displayName: "Legacy.md",
            scope: .singleFile,
            openedAt: Date(timeIntervalSince1970: 1),
            providerIdentity: nil,
            status: .needsReselection,
            bookmark: Data("legacy".utf8)
        )
        let encoded = try JSONEncoder().encode([legacy])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("metadataPath"))
        try harness.recents.save(JSONDecoder().decode([IOSStoredRecentWorkspace].self, from: encoded))
        harness.bookmarks.resolution = .resolved(url, isStale: true)
        harness.files.rootIsDirectory = false
        let grant = try await service.open(selectedURL: url, scope: .singleFile)
        XCTAssertEqual(service.recentItems().map(\.recordID), [oldID])
        XCTAssertEqual(service.recentItems().first?.status, .available)
        XCTAssertEqual(harness.scope.beganURLs, [url])
        XCTAssertEqual(service.records.count, 1)
        _ = service.invalidate(grant.workspaceID)
    }

    func testUnknownIdentityKeepsDistinctLiteralUnicodePaths() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        harness.files.rootIsDirectory = false
        for leaf in ["caf\u{00E9}.md", "cafe\u{0301}.md"] {
            let grant = try await service.open(
                selectedURL: IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/" + leaf),
                scope: .singleFile
            )
            _ = service.invalidate(grant.workspaceID)
        }
        XCTAssertEqual(service.recentItems().count, 2)
    }

    func testUnresolvableLegacyBookmarkIsNotMatchedByItsDisplayName() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let oldID = UUID()
        harness.recents.save([
            IOSStoredRecentWorkspace(
                recordID: oldID,
                displayName: "Note.md",
                scope: .singleFile,
                openedAt: Date(timeIntervalSince1970: 1),
                providerIdentity: nil,
                status: .needsReselection,
                bookmark: Data("denied".utf8)
            ),
        ])
        harness.bookmarks.resolution = IOSBookmarkResolution(url: nil, isStale: false, failure: .permissionDenied)
        harness.files.rootIsDirectory = false
        let grant = try await service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/Note.md"),
            scope: .singleFile
        )
        XCTAssertEqual(service.recentItems().count, 2)
        XCTAssertEqual(service.recentItems().first { $0.recordID == oldID }?.status, .needsReselection)
        _ = service.invalidate(grant.workspaceID)
    }

    func testTransientDestinationDoesNotRememberRefreshOrEvictRecents() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-recents/Destination")
        let old = (0 ..< 10).map { index in
            IOSStoredRecentWorkspace(
                recordID: UUID(),
                displayName: "Folder-\(index)",
                scope: .directory,
                openedAt: Date(timeIntervalSince1970: Double(index)),
                providerIdentity: nil,
                status: .needsReselection,
                bookmark: Data("bookmark-\(index)".utf8),
                metadataPath: Data(IOSWorkspacePathAuthority.pathBytes(url))
            )
        }
        harness.recents.save(old)
        let grant = try await service.openDestinationFolder(selectedURL: url)
        XCTAssertEqual(grant.scope, .directory)
        let lease = try service.acquireLease(for: grant)
        XCTAssertEqual(harness.recents.load(), old)
        _ = service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 1)
        XCTAssertEqual(harness.recents.load(), old)
    }

    func testTransientDestinationRejectsAFileWithoutChangingRecents() async throws {
        let harness = AccessHarness()
        let service = productionIdentityService(harness)
        let file = try await harness.openFile()
        _ = harness.service.invalidate(file.workspaceID)
        let old = harness.recents.load()
        do {
            _ = try await service.openDestinationFolder(selectedURL: file.rootURL)
            XCTFail("A file was accepted as a destination folder")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .invalidPath)
        }
        XCTAssertEqual(harness.recents.load(), old)
        XCTAssertTrue(service.records.isEmpty)
    }

    private func productionIdentityService(_ harness: AccessHarness) -> IOSWorkspaceAccessService {
        var ports = harness.service.ports
        ports.identity = IOSSystemProviderIdentityPort()
        return IOSWorkspaceAccessService(ports: ports)
    }
}
