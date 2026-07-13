import Foundation
import MarkdownCore

public struct MarkdownFile: Sendable, Equatable {
    public let url: URL
    public let text: String
    public let fileKind: FileKind

    public init(url: URL, text: String, fileKind: FileKind) {
        self.url = url
        self.text = text
        self.fileKind = fileKind
    }
}

public struct MarkdownFileReadResult: Sendable, Equatable {
    public let file: MarkdownFile
    public let metadata: WorkspaceCoherentFileMetadata

    public init(file: MarkdownFile, metadata: WorkspaceCoherentFileMetadata) {
        self.file = file
        self.metadata = metadata
    }
}

public enum MarkdownFileStoreError: LocalizedError, Equatable {
    case unsupportedExtension(URL)
    case unreadable(URL)
    case unwritable(URL)
    case changedIdentity(URL)
    case writeRequiresReconciliation(URL, WorkspaceIndeterminateFileWrite)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(url):
            "\(url.lastPathComponent) is not a supported Markdown or MDX file."
        case let .unreadable(url):
            "Could not read \(url.lastPathComponent) as UTF-8 Markdown."
        case let .unwritable(url):
            "Could not save changes to \(url.lastPathComponent)."
        case let .changedIdentity(url):
            "\(url.lastPathComponent) changed before it could be opened."
        case let .writeRequiresReconciliation(url, _):
            "\(url.lastPathComponent) may already contain the new bytes and must be reconciled."
        }
    }
}

public struct MarkdownFileStore: Sendable {
    public init() {}

    public func load(url: URL) throws -> MarkdownFile {
        _ = try Self.validatedFileKind(for: url)

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: url)
            return try load(at: location)
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unreadable(url)
        }
    }

    /// Loads through a caller-established root authority, walking every relative path
    /// component with `O_NOFOLLOW` and reading from the same verified descriptor.
    public func load(at location: WorkspaceFileSystemLocation) throws -> MarkdownFile {
        try loadResult(at: location, expectedIdentity: nil).file
    }

    /// Loads and validates `expectedIdentity` against metadata sampled from the same
    /// descriptor that supplied the returned bytes. No path is inspected or reopened.
    public func load(
        at location: WorkspaceFileSystemLocation,
        expecting expectedIdentity: WorkspaceFileSystemIdentity
    ) throws -> MarkdownFileReadResult {
        try loadResult(at: location, expectedIdentity: expectedIdentity)
    }

    private func loadResult(
        at location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity?
    ) throws -> MarkdownFileReadResult {
        let url = location.fileURL
        let fileKind = try Self.validatedFileKind(for: url)

        do {
            return try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                let result = try WorkspaceAnchoredFileSystem.read(
                    location,
                    maximumByteCount: nil
                )
                if let expectedIdentity,
                   result.metadata.identity != expectedIdentity
                {
                    throw MarkdownFileStoreError.changedIdentity(url)
                }
                guard let text = String(data: result.data, encoding: .utf8) else {
                    throw MarkdownFileStoreError.unreadable(url)
                }
                return MarkdownFileReadResult(
                    file: MarkdownFile(url: url, text: text, fileKind: fileKind),
                    metadata: result.metadata
                )
            }
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unreadable(url)
        }
    }

    public func save(text: String, to url: URL) throws {
        _ = try Self.validatedFileKind(for: url)

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: url)
            // The synchronous URL facade predates typed cancellation outcomes. Existing
            // callers can cancel their scheduling task while entering save, so finish this
            // transaction and map its proven outcome instead of misreporting non-commit.
            let outcome = try WorkspaceAnchoredFileSystem.$ignoresInheritedTaskCancellation
                .withValue(true) {
                    try save(
                        text: text,
                        at: location,
                        expecting: .existingOrMissing
                    )
                }
            switch outcome {
            case .committedAndDurable:
                return
            case .notCommitted:
                throw MarkdownFileStoreError.unwritable(url)
            case let .committedButIndeterminate(indeterminate):
                throw MarkdownFileStoreError.writeRequiresReconciliation(url, indeterminate)
            }
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unwritable(url)
        }
    }

    /// Preserves the writer's exact commit state for callers that own reconciliation.
    public func save(
        text: String,
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome {
        _ = try Self.validatedFileKind(for: location.fileURL)
        return WorkspaceNoFollowFileWriter.write(
            text: text,
            to: location,
            expecting: expectation
        )
    }

    private static func validatedFileKind(for url: URL) throws -> FileKind {
        guard let fileKind = FileKind(url: url) else {
            throw MarkdownFileStoreError.unsupportedExtension(url)
        }
        return fileKind
    }
}
