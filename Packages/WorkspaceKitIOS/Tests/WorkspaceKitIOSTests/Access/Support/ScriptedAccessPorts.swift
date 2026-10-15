import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS

final class ScriptedWorkspaceFiles: IOSWorkspaceFilePort, @unchecked Sendable {
    private let lock = NSLock()
    var rootIsDirectory = true
    var files: [String: IOSWorkspaceFileItem] = [:]
    var fileBytes: [String: Data] = [:]
    var listResult: Result<[IOSWorkspaceFileItem], Error> = .success([])
    var readResult: Result<Data, Error> = .success(Data("bytes".utf8))
    var parkReads = false
    var parkLists = false
    var parkMetadata = false
    var parkRemoves = false
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
    private var parkedMetadata: [(CheckedContinuation<IOSWorkspaceFileItem, Error>, IOSWorkspaceFileItem)] = []
    private var parkedRemoves: [(CheckedContinuation<Void, Error>, URL, String, Data)] = []
    private var parkedCreates: [(CheckedContinuation<IOSWorkspaceFileItem, Error>, IOSWorkspaceFileItem)] = []
    private var listedURLs: [URL] = []
    private(set) var metadataCalls = 0
    private(set) var listCalls = 0
    private(set) var readCalls = 0
    private(set) var createCalls = 0
    private(set) var removeURLs: [URL] = []

    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        let item = nextMetadataItem(url: url, relativePath: relativePath, root: root)
        lock.lock()
        let shouldPark = parkMetadata
        lock.unlock()
        if shouldPark {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                parkedMetadata.append((continuation, item))
                lock.unlock()
            }
        }
        return item
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
        let shouldPark = parkRemoves
        lock.unlock()
        _ = root
        if shouldPark {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                parkedRemoves.append((continuation, url, relativePath, providerIdentity))
                lock.unlock()
            }
            return
        }
        try removeStored(url: url, relativePath: relativePath, providerIdentity: providerIdentity)
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

    func resumeCreateUnreadable() {
        lock.lock()
        let parked = parkedCreates.removeFirst()
        lock.unlock()
        let item = parked.1
        parked.0.resume(throwing: IOSFilePersistedButUnreadable(
            url: item.url,
            relativePath: item.relativePath,
            byteCount: item.fileSize ?? 0,
            providerIdentity: item.providerIdentity,
            reason: .coordinationFailed
        ))
    }

    func resumeMetadata() {
        lock.lock()
        let parked = parkedMetadata.removeFirst()
        lock.unlock()
        parked.0.resume(returning: parked.1)
    }

    func resumeRemove() {
        lock.lock()
        let parked = parkedRemoves.removeFirst()
        lock.unlock()
        do {
            try removeStored(url: parked.1, relativePath: parked.2, providerIdentity: parked.3)
            parked.0.resume()
        } catch {
            parked.0.resume(throwing: error)
        }
    }

    var parkedMetadataCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedMetadata.count
    }

    var parkedRemoveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedRemoves.count
    }

    private func nextMetadataItem(url: URL, relativePath: String, root: URL) -> IOSWorkspaceFileItem {
        lock.lock()
        defer { lock.unlock() }
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

    private func removeStored(url: URL, relativePath: String, providerIdentity: Data) throws {
        lock.lock()
        defer { lock.unlock() }
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
