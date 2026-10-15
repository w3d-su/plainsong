import Foundation
import WorkspaceCore

struct IOSSystemWorkspaceFilePort: IOSWorkspaceFilePort {
    var timeoutNanoseconds: UInt64 = IOSWorkspaceAccessPorts.defaultTimeoutNanoseconds

    func metadata(url: URL, relativePath: String) async throws -> IOSWorkspaceFileItem {
        try await coordinate(url: url, reading: [.withoutChanges, .immediatelyAvailableMetadataOnly]) { readURL in
            try item(url: readURL, relativePath: relativePath, includeBytes: false, maximumByteCount: 0)
        }
    }

    func list(url: URL, relativePath: String) async throws -> [IOSWorkspaceFileItem] {
        try await coordinate(url: url, reading: [.withoutChanges, .immediatelyAvailableMetadataOnly]) { readURL in
            let children = try FileManager.default.contentsOfDirectory(
                at: readURL,
                includingPropertiesForKeys: Self.resourceKeys,
                options: []
            )
            return try children.map { child in
                let name = child.lastPathComponent
                let spelling = IOSWorkspacePathAuthority.childSpelling(parent: relativePath, name: name)
                return try item(url: child, relativePath: spelling, includeBytes: false, maximumByteCount: 0)
            }
        }
    }

    func readFile(url: URL, relativePath: String, maximumByteCount: Int) async throws -> Data {
        try await coordinate(url: url, reading: [.withoutChanges]) { readURL in
            let info = try item(url: readURL, relativePath: relativePath, includeBytes: false, maximumByteCount: 0)
            if info.isSymlink {
                throw IOSWorkspaceFailure.outsideGrant
            }
            if let size = info.fileSize, size > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            let data = try Data(contentsOf: readURL)
            if data.count > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            return data
        }
    }

    func createFile(url: URL, relativePath: String, data: Data) async throws -> IOSWorkspaceFileItem {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw IOSWorkspaceFailure.alreadyExists
        }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) {
            try await coordinate(url: parent, writing: []) { coordinatedParent in
                try FileManager.default.createDirectory(
                    at: coordinatedParent,
                    withIntermediateDirectories: false
                )
            }
        }
        try await coordinate(url: url, writing: []) { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path(percentEncoded: false)) {
                throw IOSWorkspaceFailure.alreadyExists
            }
            guard FileManager.default.createFile(atPath: coordinatedURL.path(percentEncoded: false), contents: data)
            else {
                throw IOSWorkspaceFailure.coordinationFailed
            }
        }
        return try await metadata(url: url, relativePath: relativePath)
    }

    func removeFile(url: URL, relativePath: String) async throws {
        _ = relativePath
        try await coordinate(url: url, writing: .forDeleting) { coordinatedURL in
            guard IOSWorkspacePathAuthority.sameFile(url, coordinatedURL) else {
                throw IOSWorkspaceFailure.indeterminate
            }
            try FileManager.default.removeItem(at: coordinatedURL)
        }
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

    private func item(
        url: URL,
        relativePath: String,
        includeBytes: Bool,
        maximumByteCount: Int
    ) throws -> IOSWorkspaceFileItem {
        _ = includeBytes
        _ = maximumByteCount
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isDirectory = values.isDirectory ?? false
        let isSymlink = values.isSymbolicLink ?? false
        if isSymlink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            if IOSWorkspacePathAuthority.rejectsSymlinkTarget(target) {
                return IOSWorkspaceFileItem(
                    relativePath: relativePath,
                    url: url,
                    isDirectory: isDirectory,
                    isSymlink: true,
                    fileSize: values.fileSize,
                    availability: .unavailable,
                    providerIdentity: nil,
                    bytes: nil
                )
            }
        }
        return IOSWorkspaceFileItem(
            relativePath: relativePath,
            url: url,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            fileSize: values.fileSize,
            availability: availability(values),
            providerIdentity: nil,
            bytes: nil
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
        try await run(timeoutNanoseconds: timeoutNanoseconds) {
            var coordinationError: NSError?
            var result: Result<T, Error>?
            let coordinator = NSFileCoordinator()
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
        try await run(timeoutNanoseconds: timeoutNanoseconds) {
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            let coordinator = NSFileCoordinator()
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

    private func run<T: Sendable>(
        timeoutNanoseconds: UInt64,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try body()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw IOSWorkspaceFailure.coordinationFailed
            }
            guard let value = try await group.next() else {
                throw IOSWorkspaceFailure.coordinationFailed
            }
            group.cancelAll()
            return value
        }
    }
}
