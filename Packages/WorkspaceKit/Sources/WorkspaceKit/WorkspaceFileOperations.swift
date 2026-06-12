import AppKit
import Foundation

public protocol WorkspaceItemRecycling: AnyObject {
    func recycle(_ urls: [URL]) async throws
}

public enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case emptyName
    case destinationExists(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "The item name cannot be empty."
        case let .destinationExists(url):
            "\(url.lastPathComponent) already exists."
        }
    }
}

public struct WorkspaceFileOperations: @unchecked Sendable {
    private let recycler: any WorkspaceItemRecycling

    public init(recycler: any WorkspaceItemRecycling = NSWorkspaceItemRecycler()) {
        self.recycler = recycler
    }

    @discardableResult
    public func createFile(named name: String, in directory: URL) throws -> URL {
        let destination = try destination(named: name, in: directory)
        try Data().write(to: destination, options: [.atomic])
        return destination
    }

    @discardableResult
    public func createFolder(named name: String, in directory: URL) throws -> URL {
        let destination = try destination(named: name, in: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        guard let parent = url.standardizedFileURL.deletingLastPathComponentIfPossible else {
            throw WorkspaceFileOperationError.emptyName
        }
        let destination = try destination(named: newName, in: parent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public func move(_ url: URL, toDirectory directory: URL) throws -> URL {
        let destination = directory
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
            .standardizedFileURL
        guard destination != url.standardizedFileURL else {
            return destination
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.destinationExists(destination)
        }

        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    public func trash(_ url: URL) async throws {
        try await recycler.recycle([url])
    }

    private func destination(named name: String, in directory: URL) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }

        let destination = directory
            .appendingPathComponent(trimmedName, isDirectory: false)
            .standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.destinationExists(destination)
        }
        return destination
    }
}

public final class NSWorkspaceItemRecycler: WorkspaceItemRecycling, @unchecked Sendable {
    public init() {}

    public func recycle(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                NSWorkspace.shared.recycle(urls) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private extension URL {
    var deletingLastPathComponentIfPossible: URL? {
        let parent = deletingLastPathComponent()
        return parent == self ? nil : parent
    }
}
