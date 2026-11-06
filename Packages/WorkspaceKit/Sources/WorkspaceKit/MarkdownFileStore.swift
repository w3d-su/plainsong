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
    public let sha256Digest: String

    public init(
        file: MarkdownFile,
        metadata: WorkspaceCoherentFileMetadata,
        sha256Digest: String
    ) {
        self.file = file
        self.metadata = metadata
        self.sha256Digest = sha256Digest
    }
}

public enum MarkdownFileStoreError: LocalizedError, Equatable {
    case unsupportedExtension(URL)
    case unreadable(URL)
    case unwritable(URL)
    /// Proven not committed: the volume cannot publish the save with an atomic rename (exFAT
    /// and FAT32 for every save, Mac OS Extended for a replacement).
    case unsupportedVolume(URL)
    /// Proven not committed: the disk or the user's quota is full.
    case insufficientSpace(URL)
    /// Proven not committed: the volume is mounted read-only.
    case readOnlyVolume(URL)
    /// Proven not committed: the file system or the App Sandbox refused the write.
    case writeNotPermitted(URL)
    case changedIdentity(URL)
    case writeNotCommittedWithCleanupRequired(URL, WorkspaceNotCommittedFileWrite)
    case committedWithCleanupRequired(URL, WorkspaceDurableFileWrite)
    case writeRequiresReconciliation(URL, WorkspaceIndeterminateFileWrite)

    /// The error for a proven non-commit. A remaining artifact is always reported; otherwise a
    /// writer reason the user can act on picks its own case, and any other reason stays
    /// `unwritable`.
    public static func notCommitted(
        _ result: WorkspaceNotCommittedFileWrite,
        destinationURL: URL
    ) -> MarkdownFileStoreError {
        guard result.artifactState == .none else {
            return .writeNotCommittedWithCleanupRequired(destinationURL, result)
        }
        return switch result.reason {
        case .unsupportedVolume: .unsupportedVolume(destinationURL)
        case .insufficientSpace: .insufficientSpace(destinationURL)
        case .readOnlyVolume: .readOnlyVolume(destinationURL)
        case .writeNotPermitted: .writeNotPermitted(destinationURL)
        default: .unwritable(destinationURL)
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(url):
            "\(url.lastPathComponent) is not a supported Markdown or MDX file."
        case let .unreadable(url):
            "Could not read \(url.lastPathComponent) as UTF-8 Markdown."
        case let .unwritable(url):
            "Could not save changes to \(url.lastPathComponent)."
        case let .unsupportedVolume(url):
            Self.refusalDescription(destinationURL: url, reason: .unsupportedVolume)
        case let .insufficientSpace(url):
            Self.refusalDescription(destinationURL: url, reason: .insufficientSpace)
        case let .readOnlyVolume(url):
            Self.refusalDescription(destinationURL: url, reason: .readOnlyVolume)
        case let .writeNotPermitted(url):
            Self.refusalDescription(destinationURL: url, reason: .writeNotPermitted)
        case let .changedIdentity(url):
            "\(url.lastPathComponent) changed before it could be opened."
        case let .writeNotCommittedWithCleanupRequired(url, result):
            Self.artifactDescription(
                destinationURL: url,
                artifactState: result.artifactState,
                destinationWasCommitted: false,
                reason: result.reason
            )
        case let .committedWithCleanupRequired(url, result):
            Self.artifactDescription(
                destinationURL: url,
                artifactState: result.cleanupState,
                destinationWasCommitted: true,
                reason: nil
            )
        case let .writeRequiresReconciliation(url, _):
            "\(url.lastPathComponent) may already contain the new bytes and must be reconciled."
        }
    }

    private static func refusalDescription(
        destinationURL: URL,
        reason: WorkspaceAnchoredFileSystemError
    ) -> String {
        let failure = "Could not save changes to \(destinationURL.lastPathComponent)"
        guard let refusal = WriteRefusal(reason) else { return "\(failure)." }
        return "\(failure) because \(refusal.cause). \(refusal.nextStep)"
    }

    private static func artifactDescription(
        destinationURL: URL,
        artifactState: WorkspaceFileWriteArtifactState,
        destinationWasCommitted: Bool,
        reason: WorkspaceAnchoredFileSystemError?
    ) -> String {
        let name = destinationURL.lastPathComponent
        let outcome = if destinationWasCommitted {
            "\(name) was saved"
        } else if let refusal = reason.flatMap(WriteRefusal.init) {
            "\(name) was not replaced because \(refusal.cause)"
        } else {
            "\(name) was not replaced"
        }
        return switch artifactState {
        case .none:
            outcome
        case let .retained(location):
            "\(outcome), but a recovery artifact was retained at \(location.fileURL.path)."
        case let .removalIndeterminate(location):
            "\(outcome), but removal of the recovery artifact at \(location.fileURL.path) could not be confirmed."
        }
    }
}

/// The cause and next step shown for a writer reason the user can act on.
private struct WriteRefusal {
    /// Completes "Could not save changes to post.md because …".
    let cause: String
    let nextStep: String

    init?(_ reason: WorkspaceAnchoredFileSystemError) {
        switch reason {
        case .unsupportedVolume:
            cause = "its disk cannot replace files safely"
            nextStep = "Plainsong saves by swapping in a complete new copy in one step, which disks " +
                "formatted as exFAT, FAT32, or Mac OS Extended do not support. Copy the file to a " +
                "folder on your Mac or to an APFS disk and edit it there."
        case .insufficientSpace:
            cause = "its disk is full"
            nextStep = "Free up space on the disk, then save again."
        case .readOnlyVolume:
            cause = "its disk is read-only"
            nextStep = "Copy the file to a folder you can write to and edit it there."
        case .writeNotPermitted:
            cause = "writing to it is not permitted"
            nextStep = "The file may be locked, its permissions may have changed, or access to its " +
                "folder may have been revoked. Check the file with Get Info in the Finder, or open it again."
        default:
            return nil
        }
    }
}

public struct MarkdownFileStore: Sendable {
    public init() {}

    public func load(url: URL) throws -> MarkdownFile {
        _ = try Self.validatedFileKind(for: url)

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: url)
            let file = try load(at: location)
            return MarkdownFile(url: url, text: file.text, fileKind: file.fileKind)
        } catch is MarkdownFileStoreError {
            // The URL compatibility facade preserves the caller's display spelling even though
            // the typed location below exposes its descriptor-canonical lexical spelling.
            throw MarkdownFileStoreError.unreadable(url)
        } catch {
            throw MarkdownFileStoreError.unreadable(url)
        }
    }

    /// Loads through a caller-established root authority, walking every relative path
    /// component with `O_NOFOLLOW` and reading from the same verified descriptor.
    public func load(at location: WorkspaceFileSystemLocation) throws -> MarkdownFile {
        try loadResult(at: location).file
    }

    /// Preserves metadata sampled from the same descriptor that supplied the returned bytes.
    public func loadResult(at location: WorkspaceFileSystemLocation) throws -> MarkdownFileReadResult {
        try performLoadResult(at: location, expectedIdentity: nil)
    }

    /// Loads and validates `expectedIdentity` against metadata sampled from the same
    /// descriptor that supplied the returned bytes. No path is inspected or reopened.
    public func load(
        at location: WorkspaceFileSystemLocation,
        expecting expectedIdentity: WorkspaceFileSystemIdentity
    ) throws -> MarkdownFileReadResult {
        try performLoadResult(at: location, expectedIdentity: expectedIdentity)
    }

    private func performLoadResult(
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
                    metadata: result.metadata,
                    sha256Digest: WorkspaceAnchoredFileSystem.sha256Digest(result.data)
                )
            }
        } catch WorkspaceAnchoredFileSystemError.missing {
            // App-owned external-change arbitration needs to distinguish deletion from an
            // unreadable replacement without reopening the retained path for a second probe.
            throw WorkspaceAnchoredFileSystemError.missing
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unreadable(url)
        }
    }

    public func save(text: String, to url: URL) throws {
        _ = try Self.validatedFileKind(for: url)

        do {
            // The synchronous URL facade predates typed cancellation outcomes. Existing
            // callers can cancel their scheduling task while entering save, so finish this
            // transaction—including authority capture for the location—and map its proven
            // outcome instead of misreporting non-commit.
            let outcome = try WorkspaceAnchoredFileSystem.$ignoresInheritedTaskCancellation
                .withValue(true) {
                    let location = try WorkspaceFileSystemLocation(fileURL: url)
                    return try save(
                        text: text,
                        at: location,
                        expecting: .existingOrMissing
                    )
                }
            try Self.mapLegacySaveOutcome(outcome, destinationURL: url)
        } catch let error as MarkdownFileStoreError {
            throw error
        } catch {
            throw MarkdownFileStoreError.unwritable(url)
        }
    }

    static func mapLegacySaveOutcome(
        _ outcome: WorkspaceFileWriteOutcome,
        destinationURL: URL
    ) throws {
        switch outcome {
        case let .committedAndDurable(result):
            guard result.cleanupState != .none else { return }
            throw MarkdownFileStoreError.committedWithCleanupRequired(destinationURL, result)
        case let .notCommitted(result):
            throw MarkdownFileStoreError.notCommitted(result, destinationURL: destinationURL)
        case let .committedButIndeterminate(indeterminate):
            throw MarkdownFileStoreError.writeRequiresReconciliation(
                destinationURL,
                indeterminate
            )
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
