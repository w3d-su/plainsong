import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

protocol LastOpenedFilePersisting: AnyObject {
    func save(_ url: URL) throws
    func restore() throws -> URL?
}

extension LastOpenedFileStore: LastOpenedFilePersisting {}

protocol RecentItemPersisting: AnyObject {
    func save(_ url: URL) throws
    func restore() throws -> [URL]
}

extension RecentItemStore: RecentItemPersisting {}

protocol ExternalReloadApplicationPreparing: Sendable {
    func prepare(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) async -> ExternalReloadApplicationPayload?
}

struct ProductionExternalReloadApplicationPreparer: ExternalReloadApplicationPreparing {
    private let willPrepare: (@Sendable () -> Void)?
    private let didPrepare: (@Sendable () -> Void)?

    init(
        willPrepare: (@Sendable () -> Void)? = nil,
        didPrepare: (@Sendable () -> Void)? = nil
    ) {
        self.willPrepare = willPrepare
        self.didPrepare = didPrepare
    }

    func prepare(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) async -> ExternalReloadApplicationPayload? {
        let preparationTask = Task<ExternalReloadApplicationPayload?, Never>.detached(
            priority: .utility
        ) {
            guard !Task.isCancelled else { return nil }
            willPrepare?()
            guard !Task.isCancelled else { return nil }
            guard let payload = ExternalReloadApplicationPayload.preparingIfNotCancelled(
                snapshot: snapshot,
                sourceSnapshot: sourceSnapshot
            ) else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            didPrepare?()
            return payload
        }
        return await withTaskCancellationHandler {
            await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
    }
}

struct FileWriteArtifactNotice: Identifiable, Equatable {
    let id: UUID
    let destinationURL: URL
    let destinationWasCommitted: Bool
    let artifactState: WorkspaceFileWriteArtifactState

    init(
        id: UUID = UUID(),
        destinationURL: URL,
        destinationWasCommitted: Bool,
        artifactState: WorkspaceFileWriteArtifactState
    ) {
        self.id = id
        self.destinationURL = destinationURL
        self.destinationWasCommitted = destinationWasCommitted
        self.artifactState = artifactState
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.destinationURL == rhs.destinationURL
            && lhs.destinationWasCommitted == rhs.destinationWasCommitted
            && lhs.artifactState == rhs.artifactState
    }
}

enum IndeterminateFileWriteReconciliationState: Equatable {
    case symbolicLink
    case notRegularFile
    case unreadable
}

struct IndeterminateFileWriteReconciliationPrompt: Equatable {
    let fileURL: URL
    let state: IndeterminateFileWriteReconciliationState
}

struct AppStateUserVisibleError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct WorkspaceTrashCleanupNotice: Identifiable, Equatable {
    let id = UUID()
    let stagingLocation: WorkspaceFileSystemLocation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stagingLocation == rhs.stagingLocation
    }
}

enum WorkspaceMutationRecoveryBannerPlacement: Equatable {
    case global
    case editor
    case hidden
}

struct RetiredEditorDocumentSession {
    let canonicalURL: URL
    let session: DocumentSession
    var bindingIDs: Set<EditorDocumentBindingID>
    var awaitingInstallations: Set<EditorDocumentBindingInstallation>
    var securityScopedAuthorityOwners: [RetiredWorkspaceAuthorityOwner]
}

enum DeferredExternalChangeResolution: Equatable {
    case reload
    case keepMine
}

struct ExternalResolutionIntentCapture: Equatable {
    let intent: DeferredExternalChangeResolution
    let sourceSnapshot: EditorDocumentSourceSnapshot
    var diskEventGeneration: UInt64
}

final class RetiredWorkspaceAuthorityOwner: @unchecked Sendable {
    let authority: SecurityScopedResourceAccess

    private let lock = NSLock()
    private var dependentSessions: Set<ObjectIdentifier> = []
    private var isStopped = false

    init(authority: SecurityScopedResourceAccess) {
        self.authority = authority
    }

    var hasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    var dependentSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dependentSessions.count
    }

    deinit {
        stop()
    }

    func retain(_ session: DocumentSession) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        dependentSessions.insert(ObjectIdentifier(session))
    }

    func release(_ session: DocumentSession) {
        let shouldStop: Bool
        lock.lock()
        dependentSessions.remove(ObjectIdentifier(session))
        shouldStop = dependentSessions.isEmpty && !isStopped
        if shouldStop {
            isStopped = true
        }
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }

    func stopIfUnused() {
        let shouldStop: Bool
        lock.lock()
        shouldStop = dependentSessions.isEmpty && !isStopped
        if shouldStop {
            isStopped = true
        }
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }

    func stop() {
        let shouldStop: Bool
        lock.lock()
        shouldStop = !isStopped
        isStopped = true
        dependentSessions.removeAll()
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }
}

enum AppStateError: LocalizedError {
    case unsupportedFile(URL)
    case missingFile(URL)
    case unresolvedExternalChange(URL)
    case invalidSessionIdentity(URL)
    case duplicateSessionOwnership(URL)
    case pendingEditorSource(URL)
    case unsafeWriteTarget(URL)
    case workspaceMutationInProgress(URL)
    case workspaceMutationRecoveryUnavailable(URL)
    case unsavedChangesPreventTermination(URL)
    case recoveryDestinationConflictsOriginal(URL)
    /// A production extra scene refuses every file and root open until PR D2.
    case windowFileOpenRefused

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(url):
            "\(url.lastPathComponent) is not a supported Markdown file."
        case let .missingFile(url):
            "\(url.lastPathComponent) is no longer on disk. Save a copy or close it."
        case let .unresolvedExternalChange(url):
            "\(url.lastPathComponent) changed on disk. Choose Reload or Keep mine before saving."
        case let .invalidSessionIdentity(url):
            "The cached editor session for \(url.lastPathComponent) no longer matches that file."
        case let .duplicateSessionOwnership(url):
            "More than one editor session owns \(url.lastPathComponent)."
        case let .pendingEditorSource(url):
            "\(url.lastPathComponent) still has editor input waiting to synchronize."
        case let .unsafeWriteTarget(url):
            "\(url.lastPathComponent) no longer refers to the file owned by this editor session."
        case let .workspaceMutationInProgress(url):
            "\(url.lastPathComponent) is being moved. Wait for the workspace operation to finish."
        case let .workspaceMutationRecoveryUnavailable(url):
            "Saved recovery information for \(url.lastPathComponent) could not be loaded. " +
                "Stop tracking the unreadable recovery before reading or writing files."
        case let .unsavedChangesPreventTermination(url):
            "\(url.lastPathComponent) still has changes that are not safely saved or recovered."
        case let .recoveryDestinationConflictsOriginal(url):
            "Choose a different name or folder for the recovery copy; " +
                "\(url.lastPathComponent) may belong to another file."
        case .windowFileOpenRefused:
            "This window cannot open files. Use the existing window."
        }
    }
}
