import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRootPresenterReviewTests: XCTestCase {
    func testEvictionKeepsThePresenterAndLaterRootChangesRefreshTheDirectory() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
        let service = harness.service
        let presenter = IOSRootFilePresenter(root: grant.rootURL) { notice in
            Task { @MainActor in
                service.ingest(IOSQueuedWorkspaceNotice(
                    workspaceID: grant.workspaceID, generation: grant.accessGeneration,
                    rootToken: record.rootToken, notice: notice
                ))
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var events: [IOSWorkspaceEvent] = []
        _ = service.observe { events.append($0) }
        presenter.accommodatePresentedItemEviction { XCTAssertNil($0) }
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0 === presenter })
        await waitUntil { events.contains { event in
            if case let .unavailable(identity, .offline) = event {
                return identity == grant.workspaceID
            }
            return false
        } }
        presenter.presentedItemDidChange()
        await waitUntil { service.snapshot(for: grant.workspaceID) != nil }
        XCTAssertEqual(harness.files.listCalls, 1)
        XCTAssertFalse(events.contains { event in
            if case .resourceChanged = event {
                return true
            }
            return false
        }, "a directory root callback must not invent Folder/Folder")
    }

    func testUnprovedRootMoveRevokesTheOldGrantWithoutInventingAChild() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        watcher.emit(.rootMoved, identity: grant.workspaceID)
        await waitUntil { harness.service.records[grant.workspaceID]?.revoked == true }
        XCTAssertThrowsError(try harness.service.acquireLease(for: grant))
        XCTAssertFalse(lease.isReleased)
        XCTAssertEqual(harness.scope.endCount, 0, "existing consumers must drain before scope stop")
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.rootURL, grant.rootURL)
        XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
        XCTAssertFalse(events.contains { event in
            if case .resourceChanged = event {
                return true
            }
            return false
        })
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    func testRootDeletionRevokesTheGrant() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openFile()
        watcher.emit(.rootDeleted, identity: grant.workspaceID)
        await waitUntil { harness.service.currentGrant(for: grant.workspaceID) == nil }
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    func testSingleFileRootChangeReportsTheGrantedFile() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openFile()
        var locations: [IOSFileLocation] = []
        _ = harness.service.observe { event in
            if case let .resourceChanged(location) = event {
                locations.append(location)
            }
        }
        watcher.emit(.rootChanged, identity: grant.workspaceID)
        await waitUntil { locations.count == 1 }
        XCTAssertEqual(locations.first?.fileURL, grant.rootURL)
        XCTAssertEqual(locations.first?.relativePath, "Note.md")
    }

    /// A device picker root keeps `/private/var/mobile/…`, and a callback may spell the
    /// same child through the other side of that symlink. A symlinked folder stands in
    /// for `/private`, in both directions, including leaves that no longer exist.
    func testSubitemCallbacksMapAcrossASymlinkedRootSpelling() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-root-presenter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let notes = real.appendingPathComponent("Folder/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: notes.appendingPathComponent("a.md"))
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasFolder = alias.appendingPathComponent("Folder", isDirectory: true)
        let resolvedFolder = IOSWorkspacePathAuthority.resolvedDirectory(aliasFolder)
        XCTAssertNil(IOSWorkspacePathAuthority.relativeSpelling(
            root: aliasFolder,
            file: resolvedFolder.appendingPathComponent("notes/a.md")
        ))

        let log = NoticeLog()
        let aliasRooted = IOSRootFilePresenter(root: aliasFolder) { log.append($0) }
        aliasRooted.presentedSubitemDidChange(at: resolvedFolder.appendingPathComponent("notes/a.md"))
        aliasRooted.presentedSubitemDidChange(at: real.appendingPathComponent("Other.md"))
        aliasRooted.presentedSubitemDidChange(at: real.appendingPathComponent("Folder2/x.md"))

        let resolvedRooted = IOSRootFilePresenter(root: resolvedFolder) { log.append($0) }
        resolvedRooted.presentedSubitemDidChange(at: aliasFolder.appendingPathComponent("notes/a.md"))
        resolvedRooted.presentedSubitem(
            at: aliasFolder.appendingPathComponent("notes/gone.md"),
            didMoveTo: aliasFolder.appendingPathComponent("notes/b.md")
        )
        resolvedRooted.accommodatePresentedSubitemDeletion(at: aliasFolder.appendingPathComponent("notes/a.md")) {
            XCTAssertNil($0)
        }

        XCTAssertEqual(log.entries, [
            "changed notes/a.md",
            "changed notes/a.md",
            "moved notes/gone.md notes/b.md",
            "deleted notes/a.md",
        ])
    }

    /// A file presenter spells a folder child with a trailing slash (`…/notes/`). Those
    /// callbacks map like file callbacks, through either spelling of a symlinked root,
    /// and a folder moved out of the workspace reports its own name, not an empty one.
    func testFolderCallbacksWithATrailingSlashMap() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-root-presenter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let folder = real.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("notes/drafts", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasFolder = alias.appendingPathComponent("Folder", isDirectory: true)
        let resolvedFolder = IOSWorkspacePathAuthority.resolvedDirectory(aliasFolder)
        let notes = resolvedFolder.appendingPathComponent("notes", isDirectory: true)
        XCTAssertTrue(notes.path(percentEncoded: false).hasSuffix("/notes/"))

        let log = NoticeLog()
        let presenter = IOSRootFilePresenter(root: resolvedFolder) { log.append($0) }
        presenter.presentedSubitemDidAppear(at: notes)
        presenter.presentedSubitemDidChange(at: aliasFolder.appendingPathComponent("notes/drafts", isDirectory: true))
        presenter.presentedSubitem(
            at: notes.appendingPathComponent("old", isDirectory: true),
            didMoveTo: notes.appendingPathComponent("new", isDirectory: true)
        )
        presenter.presentedSubitem(
            at: notes.appendingPathComponent("drafts", isDirectory: true),
            didMoveTo: base.appendingPathComponent("Elsewhere/drafts", isDirectory: true)
        )
        presenter.accommodatePresentedSubitemDeletion(at: notes) {
            XCTAssertNil($0)
        }
        presenter.presentedSubitemDidChange(at: resolvedFolder)
        presenter.presentedSubitemDidChange(at: real.appendingPathComponent("Folder2/", isDirectory: true))

        XCTAssertEqual(log.entries, [
            "changed notes",
            "changed notes/drafts",
            "moved notes/old notes/new",
            "moved notes/drafts drafts",
            "deleted notes",
        ])
    }
}

private final class NoticeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ notice: IOSExternalWorkspaceNotice) {
        let line = switch notice {
        case let .changed(relativePath):
            "changed \(relativePath)"
        case let .deleted(relativePath):
            "deleted \(relativePath)"
        case let .moved(from, to):
            "moved \(from) \(to)"
        default:
            "other"
        }
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
}
