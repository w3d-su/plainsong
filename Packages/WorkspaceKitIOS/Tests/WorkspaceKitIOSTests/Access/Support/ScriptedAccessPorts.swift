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
    var parkAfterPersist = false
    var failMetadataAfterPersist = false
    var nestedListing: (@Sendable (URL, String) -> [IOSWorkspaceFileItem])?
    /// Nil uses the relative-path bytes. A closure may return nil when the provider has no identity.
    var mintedIdentity: (@Sendable (String) -> Data?)?
    /// When set, removeIfOwned treats this as the live identity and will not delete a mismatch.
    var replacementIdentity: Data?
    /// After the next metadata of an existing leaf, install this identity and flip the first byte.
    var swapIdentityAfterMetadata: Data?
    private var parkedReads: [CheckedContinuation<IOSWorkspaceFilePayload, Error>] = []
    private var parkedReadURLs: [URL] = []
    private var parkedLists: [CheckedContinuation<[IOSWorkspaceFileItem], Error>] = []
    private var parkedCreates: [(CheckedContinuation<IOSWorkspaceFileItem, Error>, IOSWorkspaceFileItem)] = []
    private var listedURLs: [URL] = []
    private(set) var metadataCalls = 0
    private(set) var listCalls = 0
    private(set) var readCalls = 0
    private(set) var createCalls = 0
    private(set) var removeURLs: [URL] = []

    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        lock.lock()
        metadataCalls += 1
        let stored = files[relativePath]
        let directory = rootIsDirectory
        if let stored, !stored.isDirectory, let swap = swapIdentityAfterMetadata {
            swapIdentityAfterMetadata = nil
            replacementIdentity = swap
            if var bytes = fileBytes[relativePath], !bytes.isEmpty {
                bytes[0] ^= 0xFF
                fileBytes[relativePath] = bytes
            }
        }
        lock.unlock()
        _ = root
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

    func list(url: URL, relativePath: String, root: URL) async throws -> [IOSWorkspaceFileItem] {
        lock.lock()
        listCalls += 1
        listedURLs.append(url)
        let shouldPark = parkLists
        let nested = nestedListing
        let result = listResult
        let calls = listCalls
        lock.unlock()
        _ = root
        if calls > 8 {
            throw IOSWorkspaceFailure.coordinationFailed
        }
        if shouldPark {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedLists.append(continuation)
                lock.unlock()
            }
        }
        if let nested {
            return nested(url, relativePath)
        }
        return try result.get()
    }

    func readFile(
        url: URL,
        relativePath: String,
        maximumByteCount: Int,
        root: URL
    ) async throws -> IOSWorkspaceFilePayload {
        lock.lock()
        readCalls += 1
        let shouldPark = parkReads
        let stored = fileBytes[relativePath]
        let result = readResult
        lock.unlock()
        _ = (maximumByteCount, root)
        if shouldPark {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedReads.append(continuation)
                parkedReadURLs.append(url)
                lock.unlock()
            }
        }
        if let stored {
            return IOSWorkspaceFilePayload(data: stored, coordinatedURL: url)
        }
        return try IOSWorkspaceFilePayload(data: result.get(), coordinatedURL: url)
    }

    func createFile(url: URL, relativePath: String, data: Data, root: URL) async throws -> IOSWorkspaceFileItem {
        let decision = try createDecision(url: url, relativePath: relativePath, data: data, root: root)
        switch decision {
        case let .ready(item):
            return item
        case let .park(item):
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedCreates.append((continuation, item))
                lock.unlock()
            }
        case let .unreadable(item):
            throw IOSFilePersistedButUnreadable(
                url: item.url,
                relativePath: item.relativePath,
                byteCount: data.count,
                providerIdentity: item.providerIdentity,
                reason: .coordinationFailed
            )
        }
    }

    func removeIfOwned(url: URL, relativePath: String, root: URL, providerIdentity: Data) async throws {
        lock.lock()
        defer { lock.unlock() }
        _ = root
        let current = replacementIdentity ?? files[relativePath]?.providerIdentity ?? Data(relativePath.utf8)
        guard current == providerIdentity else {
            throw IOSWorkspaceFailure.indeterminate
        }
        guard fileBytes[relativePath] != nil else {
            throw IOSWorkspaceFailure.notFound
        }
        removeURLs.append(url)
        files[relativePath] = nil
        fileBytes[relativePath] = nil
    }

    private enum CreateDecision {
        case ready(IOSWorkspaceFileItem)
        case park(IOSWorkspaceFileItem)
        case unreadable(IOSWorkspaceFileItem)
    }

    private func createDecision(
        url: URL,
        relativePath: String,
        data: Data,
        root: URL
    ) throws -> CreateDecision {
        lock.lock()
        defer { lock.unlock() }
        _ = root
        createCalls += 1
        if fileBytes[relativePath] != nil {
            throw IOSWorkspaceFailure.alreadyExists
        }
        let identity: Data? = if let mintedIdentity {
            mintedIdentity(relativePath)
        } else {
            Data(relativePath.utf8)
        }
        let item = IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: url,
            isDirectory: false,
            isSymlink: false,
            fileSize: data.count,
            availability: .available(canWrite: true),
            providerIdentity: identity,
            bytes: nil
        )
        files[relativePath] = item
        fileBytes[relativePath] = data
        if parkAfterPersist {
            return .park(item)
        }
        if failMetadataAfterPersist {
            return .unreadable(item)
        }
        return .ready(item)
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
        let url = parkedReadURLs.removeFirst()
        lock.unlock()
        switch result {
        case let .success(data):
            continuation.resume(returning: IOSWorkspaceFilePayload(data: data, coordinatedURL: url))
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    func resumeCreate() {
        lock.lock()
        let parked = parkedCreates.removeFirst()
        lock.unlock()
        parked.0.resume(returning: parked.1)
    }

    var parkedCreateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedCreates.count
    }

    func listedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return listedURLs.map { $0.path(percentEncoded: false) }
    }

    func bytes(for relativePath: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return fileBytes[relativePath]
    }

    func replaceBytes(_ data: Data, relativePath: String, identity: Data) {
        lock.lock()
        fileBytes[relativePath] = data
        if var item = files[relativePath] {
            item.fileSize = data.count
            files[relativePath] = item
        }
        replacementIdentity = identity
        lock.unlock()
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
