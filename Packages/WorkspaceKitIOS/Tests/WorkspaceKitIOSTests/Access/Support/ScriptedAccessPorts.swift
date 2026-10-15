import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS

final class ScriptedScopePort: IOSSecurityScopePort, @unchecked Sendable {
    private let lock = NSLock()
    private var began: [URL] = []
    private var ended: [URL] = []
    var admission: IOSScopeAdmission = .started

    func begin(url: URL, provenance: IOSAccessProvenance) -> IOSScopeAdmission {
        lock.lock()
        defer { lock.unlock() }
        began.append(url)
        _ = provenance
        return admission
    }

    func end(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        ended.append(url)
    }

    var beganURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return began
    }

    var endCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ended.count
    }
}

final class ScriptedBookmarkPort: IOSBookmarkPort, @unchecked Sendable {
    private let lock = NSLock()
    var resolution = IOSBookmarkResolution(url: nil, isStale: false, failure: nil)
    var refreshed = Data("refreshed-bookmark".utf8)
    private(set) var bookmarkCalls = 0

    func bookmark(for url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        bookmarkCalls += 1
        _ = url
        return refreshed
    }

    func resolve(_ bookmark: Data) throws -> IOSBookmarkResolution {
        _ = bookmark
        return resolution
    }

    var bookmarkCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bookmarkCalls
    }
}

final class ScriptedIdentityPort: IOSProviderIdentityPort, @unchecked Sendable {
    var identity: Data?

    func identity(for url: URL, relativePath: String) -> Data? {
        _ = (url, relativePath)
        return identity
    }
}

final class ScriptedRecentStore: IOSRecentWorkspaceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [IOSStoredRecentWorkspace] = []

    func load() -> [IOSStoredRecentWorkspace] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func save(_ items: [IOSStoredRecentWorkspace]) {
        lock.lock()
        defer { lock.unlock() }
        self.items = items
    }
}

final class ScriptedWorkspaceFiles: IOSWorkspaceFilePort, @unchecked Sendable {
    private let lock = NSLock()
    var rootIsDirectory = true
    var files: [String: IOSWorkspaceFileItem] = [:]
    var fileBytes: [String: Data] = [:]
    var listResult: Result<[IOSWorkspaceFileItem], Error> = .success([])
    var readResult: Result<Data, Error> = .success(Data("bytes".utf8))
    var parkReads = false
    var parkLists = false
    private var parkedReads: [CheckedContinuation<Data, Error>] = []
    private var parkedLists: [CheckedContinuation<[IOSWorkspaceFileItem], Error>] = []
    private(set) var metadataCalls = 0
    private(set) var listCalls = 0
    private(set) var readCalls = 0
    private(set) var createCalls = 0
    private(set) var removeURLs: [URL] = []

    func metadata(url: URL, relativePath: String) async throws -> IOSWorkspaceFileItem {
        lock.lock()
        metadataCalls += 1
        let stored = files[relativePath]
        let directory = rootIsDirectory
        lock.unlock()
        if let stored {
            return stored
        }
        return IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: url,
            isDirectory: directory,
            isSymlink: false,
            fileSize: directory ? nil : 0,
            availability: .available(canWrite: true),
            providerIdentity: nil,
            bytes: nil
        )
    }

    func list(url: URL, relativePath: String) async throws -> [IOSWorkspaceFileItem] {
        lock.lock()
        listCalls += 1
        let shouldPark = parkLists
        let result = listResult
        lock.unlock()
        _ = (url, relativePath)
        if shouldPark {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedLists.append(continuation)
                lock.unlock()
            }
        }
        return try result.get()
    }

    func readFile(url: URL, relativePath: String, maximumByteCount: Int) async throws -> Data {
        lock.lock()
        readCalls += 1
        let shouldPark = parkReads
        let stored = fileBytes[relativePath]
        let result = readResult
        lock.unlock()
        _ = (url, maximumByteCount)
        if shouldPark {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedReads.append(continuation)
                lock.unlock()
            }
        }
        if let stored {
            return stored
        }
        return try result.get()
    }

    func createFile(url: URL, relativePath: String, data: Data) async throws -> IOSWorkspaceFileItem {
        lock.lock()
        defer { lock.unlock() }
        createCalls += 1
        if fileBytes[relativePath] != nil {
            throw IOSWorkspaceFailure.alreadyExists
        }
        let item = IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: url,
            isDirectory: false,
            isSymlink: false,
            fileSize: data.count,
            availability: .available(canWrite: true),
            providerIdentity: Data(relativePath.utf8),
            bytes: nil
        )
        files[relativePath] = item
        fileBytes[relativePath] = data
        return item
    }

    func removeFile(url: URL, relativePath: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        removeURLs.append(url)
        files[relativePath] = nil
        fileBytes[relativePath] = nil
    }

    var parkedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedReads.count
    }

    var parkedListCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedLists.count
    }

    var ioCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCalls + listCalls + readCalls + createCalls + removeURLs.count
    }

    func resumeRead(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = parkedReads.removeFirst()
        lock.unlock()
        continuation.resume(with: result)
    }

    func resumeList(_ result: Result<[IOSWorkspaceFileItem], Error>, at index: Int = 0) {
        lock.lock()
        let continuation = parkedLists.remove(at: index)
        lock.unlock()
        continuation.resume(with: result)
    }

    func contains(_ relativePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileBytes[relativePath] != nil
    }

    func removedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return removeURLs.map { IOSWorkspacePathAuthority.lastComponent($0.path(percentEncoded: false)) }
    }
}

@MainActor
struct AccessHarness {
    let scope = ScriptedScopePort()
    let bookmarks = ScriptedBookmarkPort()
    let identity = ScriptedIdentityPort()
    let files = ScriptedWorkspaceFiles()
    let recents = ScriptedRecentStore()
    let service: IOSWorkspaceAccessService
    var events: [IOSWorkspaceEvent] = []

    init() {
        service = IOSWorkspaceAccessService(
            ports: IOSWorkspaceAccessPorts(
                scope: scope,
                bookmarks: bookmarks,
                identity: identity,
                files: files,
                recents: recents,
                watcher: IOSIdleWorkspaceWatcher(),
                clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                coordinationTimeoutNanoseconds: 5_000_000_000
            )
        )
    }

    func openDirectory(_ path: String = "/tmp/plainsong-lane06/Folder") async throws -> IOSWorkspaceGrant {
        files.rootIsDirectory = true
        return try await service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: path),
            scope: .directory
        )
    }

    func openFile(_ path: String = "/tmp/plainsong-lane06/Folder/Note.md") async throws -> IOSWorkspaceGrant {
        files.rootIsDirectory = false
        return try await service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: path),
            scope: .singleFile
        )
    }

    func location(
        grant: IOSWorkspaceGrant,
        relativePath: String,
        identityData: Data? = nil
    ) -> IOSFileLocation {
        IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: relativePath,
            fileURL: IOSWorkspacePathAuthority.fileURL(
                path: IOSWorkspacePathAuthority.joined(root: grant.rootURL, relativePath: relativePath)
            ),
            resourceID: identityData.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
        )
    }
}

func waitUntil(_ predicate: @escaping () -> Bool) async {
    for _ in 0 ..< 50 {
        if predicate() {
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
