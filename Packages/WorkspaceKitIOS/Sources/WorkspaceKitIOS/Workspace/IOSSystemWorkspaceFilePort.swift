import Foundation
import WorkspaceCore

struct IOSSystemWorkspaceFilePort: IOSWorkspaceFilePort {
    var timeoutNanoseconds: UInt64 = IOSWorkspaceAccessPorts.defaultTimeoutNanoseconds

    func metadata(url: URL, relativePath: String, root: URL) async throws -> IOSWorkspaceFileItem {
        try await coordinate(url: url, reading: [.withoutChanges, .immediatelyAvailableMetadataOnly]) { readURL in
            let proven = try IOSWorkspaceRootAuthority.proveExisting(readURL, root: root)
            let logical = logicalFileURL(requested: url, relativePath: relativePath, root: root)
            return try item(logicalURL: logical, statURL: proven, relativePath: relativePath, provedURL: proven)
        }
    }

    func list(url: URL, relativePath: String, root: URL) async throws -> [IOSWorkspaceFileItem] {
        try await coordinate(url: url, reading: [.withoutChanges, .immediatelyAvailableMetadataOnly]) { readURL in
            let proven = try IOSWorkspaceRootAuthority.proveExisting(readURL, root: root)
            let children = try FileManager.default.contentsOfDirectory(
                at: proven,
                includingPropertiesForKeys: Self.resourceKeys,
                options: []
            )
            return try children.map { child in
                let name = child.lastPathComponent
                let spelling = IOSWorkspacePathAuthority.childSpelling(parent: relativePath, name: name)
                let logical = IOSWorkspacePathAuthority.fileURL(
                    path: IOSWorkspacePathAuthority.joined(root: root, relativePath: spelling)
                )
                return try item(logicalURL: logical, statURL: child, relativePath: spelling, provedURL: child)
            }
        }
    }

    func readFile(
        url: URL,
        relativePath: String,
        maximumByteCount: Int,
        root: URL
    ) async throws -> IOSWorkspaceFilePayload {
        try await coordinate(url: url, reading: [.withoutChanges]) { readURL in
            let proven = try IOSWorkspaceRootAuthority.proveExisting(readURL, root: root)
            if try isSymbolicLink(readURL) {
                throw IOSWorkspaceFailure.outsideGrant
            }
            let info = try item(
                logicalURL: url,
                statURL: proven,
                relativePath: relativePath,
                provedURL: proven
            )
            if info.isSymlink {
                throw IOSWorkspaceFailure.outsideGrant
            }
            if let size = info.fileSize, size > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            let data = try Data(contentsOf: proven)
            if data.count > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            return IOSWorkspaceFilePayload(data: data, coordinatedURL: proven)
        }
    }

    func createFile(url: URL, relativePath: String, data: Data, root: URL) async throws -> IOSWorkspaceFileItem {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw IOSWorkspaceFailure.alreadyExists
        }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) {
            try await coordinate(url: parent, writing: []) { coordinatedParent in
                let provenParent = try IOSWorkspaceRootAuthority.proveNewLeaf(coordinatedParent, root: root)
                try FileManager.default.createDirectory(
                    at: provenParent,
                    withIntermediateDirectories: false
                )
            }
        }
        try await coordinate(url: url, writing: []) { coordinatedURL in
            let proven = try IOSWorkspaceRootAuthority.proveNewLeaf(coordinatedURL, root: root)
            if FileManager.default.fileExists(atPath: proven.path(percentEncoded: false)) {
                throw IOSWorkspaceFailure.alreadyExists
            }
            guard FileManager.default.createFile(
                atPath: proven.path(percentEncoded: false),
                contents: data
            ) else {
                throw IOSWorkspaceFailure.coordinationFailed
            }
        }
        do {
            return try await metadata(url: url, relativePath: relativePath, root: root)
        } catch {
            throw IOSFilePersistedButUnreadable(
                url: url,
                relativePath: relativePath,
                byteCount: data.count,
                providerIdentity: nil,
                reason: (error as? IOSWorkspaceFailure) ?? IOSWorkspaceFailureMapping.map(error)
            )
        }
    }

    func removeIfOwned(url: URL, relativePath: String, root: URL, providerIdentity: Data) async throws {
        try await coordinate(url: url, writing: .forDeleting) { coordinatedURL in
            if try isSymbolicLink(coordinatedURL) {
                throw IOSWorkspaceFailure.indeterminate
            }
            let proven = try IOSWorkspaceRootAuthority.proveExisting(coordinatedURL, root: root)
            let info = try item(
                logicalURL: url,
                statURL: proven,
                relativePath: relativePath,
                provedURL: proven
            )
            if info.isSymlink || info.isDirectory {
                throw IOSWorkspaceFailure.indeterminate
            }
            guard let identity = info.providerIdentity, identity == providerIdentity else {
                throw IOSWorkspaceFailure.indeterminate
            }
            try FileManager.default.removeItem(at: proven)
        }
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .isWritableKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemIsDownloadingKey,
    ]

    private func logicalFileURL(requested: URL, relativePath: String, root: URL) -> URL {
        if IOSWorkspacePathAuthority.sameFile(requested, root) {
            return requested
        }
        guard WorkspaceRelativePath(spelling: relativePath) != nil else { return requested }
        return IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: root, relativePath: relativePath)
        )
    }

    private func item(
        logicalURL: URL,
        statURL: URL,
        relativePath: String,
        provedURL: URL
    ) throws -> IOSWorkspaceFileItem {
        let values = try statURL.resourceValues(forKeys: Set(Self.resourceKeys))
        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        return IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: logicalURL,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            fileSize: values.fileSize,
            availability: availability(values),
            providerIdentity: nil,
            bytes: nil,
            provedURL: provedURL
        )
    }

    private func availability(_ values: URLResourceValues) -> IOSFileAvailability {
        if values.ubiquitousItemDownloadingError != nil {
            return .offline
        }
        if values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.notDownloaded
            || values.ubiquitousItemIsDownloading == true
        {
            return .downloading
        }
        return .available(canWrite: values.isWritable ?? false)
    }

    private func coordinate<T: Sendable>(
        url: URL,
        reading options: NSFileCoordinator.ReadingOptions,
        body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await run { coordinator in
            var coordinationError: NSError?
            var result: Result<T, Error>?
            coordinator.coordinate(readingItemAt: url, options: options, error: &coordinationError) { readURL in
                result = Result { try body(readURL) }
            }
            if let coordinationError {
                throw IOSWorkspaceFailureMapping.map(coordinationError)
            }
            guard let result else { throw IOSWorkspaceFailure.coordinationFailed }
            return try result.get()
        }
    }

    private func coordinate(
        url: URL,
        writing options: NSFileCoordinator.WritingOptions,
        body: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        try await run { coordinator in
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { writeURL in
                result = Result { try body(writeURL) }
            }
            if let coordinationError {
                throw IOSWorkspaceFailureMapping.map(coordinationError)
            }
            guard let result else { throw IOSWorkspaceFailure.coordinationFailed }
            try result.get()
        }
    }

    /// Cancels the coordinator at the deadline. The continuation resumes only after `coordinate` returns,
    /// so a presenter stall ends when `cancel()` runs instead of when a task group finishes the child.
    private func run<T: Sendable>(
        _ body: @escaping @Sendable (NSFileCoordinator) throws -> T
    ) async throws -> T {
        let handle = IOSCoordinatorHandle()
        let once = IOSOnceFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    handle.cancel()
                }
                Task.detached {
                    let coordinator = handle.begin()
                    let result = Result { try body(coordinator) }
                    timeout.cancel()
                    if once.claim() {
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}
