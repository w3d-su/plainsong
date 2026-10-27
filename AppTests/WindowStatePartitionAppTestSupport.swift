@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// The §3.2 home of each of the 121 stored properties `AppState` had before Windows PR B1.
enum WindowStatePartitionInventory {
    static let window: Set<String> = [
        "currentDocument", "documentChangeCancellable", "layoutMode", "wysiwygFallbackMessage",
        "editorFocusRequestID", "editorNavigationCommand", "editorNavigationChannel", "editorFindHost",
        "workspaceRootURL", "workspaceTree", "showAllFiles",
        "workspaceSearchState", "workspaceSearchUI", "workspaceSearchFocusKeyEpoch",
        "workspaceSearchFocusKeyWindowCheck", "workspaceSidebarHiddenWindows", "workspaceSearchTask",
        "workspaceSearchEditRefresh", "workspaceSearchTaskToken", "workspaceSearchQueryGeneration",
        "workspaceSearchRefreshIntent", "workspaceSearchPostActivationHook",
        "completionWorkspace", "completionWorkspaceTask", "completionWorkspaceBaseCache",
        "presentedError", "externalChangePrompt", "missingFilePrompt",
        "indeterminateFileWriteReconciliationPrompt", "exportHTMLStatus", "exportHTMLOperations",
    ]

    static let root: Set<String> = [
        "workspaceSnapshot", "workspaceSearchRootAuthority", "workspaceInstalledCaptureGeneration",
        "workspaceGeneration", "workspaceReloadTask", "workspaceReloadPostProofHook",
        "workspaceReloadPostLoadHook", "workspaceReloadPostPrepareHook", "workspaceAccess",
        "workspaceWatcher", "workspaceMutationRefreshPending", "workspaceMutationExternalRefreshPending",
        "workspaceMutationRefreshRootAuthority", "workspaceImageAssetInsertionCount",
        "editorImageAssetDiscardEventHandler", "editorImageThumbnailRefreshProxy",
    ]

    static let registry: Set<String> = [
        // Per file: writer, bindings, external state, cache/LRU, proofs, quarantine, fences.
        "isSaving", "autosaveTask", "statisticsTask", "sessionAutosaveTasks", "sessionStatisticsTasks",
        "editorDocumentBindingIDs", "editorDocumentBindingSessions", "editorBindingInstallations",
        "editorWriterInstallations", "pendingEditorSourceInstallations",
        "editorDocumentSourceSynchronizers", "editorDocumentSourceFullComparisonCounts",
        "retiredEditorDocumentSessions", "sessionLifecycleGenerations",
        "deferredExternalChangeResolutions", "externalResolutionIntentCaptures", "externalReloadTasks",
        "externalDiskInspectionTasks", "pendingExternalReloadApplications", "nextExternalReloadGeneration",
        "externalDiskEventGenerations", "lastKnownDiskHashes", "lastKnownDiskModificationDates",
        "pendingExternalTexts", "pendingExternalFileVersions", "detachedSessionURLs",
        "anchoredSessionFileBindings", "unanchoredManagedSessionOwnershipProofs",
        "editorImageAssetDocumentAuthorities", "indeterminateSessionWrites",
        "indeterminateSessionWriteContexts",
        // App-global: one cache/LRU, one namespace transaction, one recovery loader.
        "sessionCache", "sessionPolicy", "workspaceMutationWriteFences", "workspaceMutationNamespaceDepth",
        "indeterminateWorkspaceMutationSessions", "workspaceMutationRecoveries",
        "workspaceMutationOperationRecoveryRecords", "workspaceMutationOperationRecoveryIDsWithUnpromotedText",
        "workspaceMutationRecoveryIDBySession", "workspaceMutationTextRecoveryContexts",
        "workspaceMutationTextRecoverySessions", "workspaceMutationTextRecoveryTasks",
        "pendingWorkspaceMutationTextRecoveryRecords", "pendingWorkspaceMutationOperationRecoveryRecords",
        "workspaceMutationRecoveryLoadErrors", "workspaceMutationOperationRecoveryLoadError",
        "workspaceMutationTextRecoveryLoadError", "workspaceMutationOperationRecoveryLoadFailed",
        "workspaceMutationTextRecoveryLoadFailed", "workspaceMutationReconciliationPrompt",
        "fileWriteArtifactNotices", "workspaceTrashCleanupNotices", "recentItemURLs",
        "shouldRestoreLastOpenedFile", "didAttemptRestore",
        "preferences", "isWYSIWYGMechanismHealthy", "userDefaults",
        // App-global services and test seams.
        "fileStore", "coherentFileReader", "externalReloadApplicationPreparer", "lastOpenedFileStore",
        "recentItemStore", "directoryScanner", "workspaceSearchStreamProvider", "workspaceSearchLimits",
        "workspaceSearchDebounceNanoseconds", "fileOperations", "workspaceMutationOperationRecoveryStore",
        "workspaceMutationTextRecoveryStore", "reportedTrashBookmarkAccess", "editorImageThumbnailAdapter",
        "anchoredFileSaveOverride",
    ]
}

/// One mutation of a Replace authority input, through the façade or its owning container.
struct WindowStatePartitionAuthorityMutation {
    let input: String
    let path: String
    let apply: @MainActor (AppState) -> Void
}

/// One write of a hooked input, applied directly to a container: an `AppState`'s own or a
/// bare one that was never connected.
struct WindowStatePartitionInputWrite<Container> {
    let input: String
    let apply: @MainActor (Container) -> Void
}

/// Collects `UnwiredContainerHook` reports instead of letting them stop the test, until `stop()`.
@MainActor
final class UnwiredContainerHookRecorder {
    struct Report: Equatable {
        let hook: String
        let fileID: String
        let line: UInt
    }

    private(set) var reports: [Report] = []

    init() {
        precondition(UnwiredContainerHook.reportOverrideForTesting == nil, "One recorder at a time")
        UnwiredContainerHook.reportOverrideForTesting = { [weak self] hook, fileID, line in
            self?.reports.append(Report(hook: "\(hook)", fileID: "\(fileID)", line: line))
        }
    }

    func stop() {
        UnwiredContainerHook.reportOverrideForTesting = nil
    }

    func reports(for hook: String) -> [Report] {
        reports.filter { $0.hook == hook }
    }
}

/// A file-backed current document on a real file, plus the anchored location the external
/// reload and inspection task values need.
@MainActor
struct WindowStatePartitionFixture {
    let appState: AppState
    let location: WorkspaceFileSystemLocation

    static func make(testCase: XCTestCase) throws -> WindowStatePartitionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStatePartitionAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: directory)
        let location = try authority.location(relativePath: "post.md")
        try Data("hit one".utf8).write(to: location.fileURL)
        let session = DocumentSession(text: "hit one", url: location.fileURL, fileKind: .markdown)
        return WindowStatePartitionFixture(
            appState: AppState(currentDocument: session, shouldRestoreLastOpenedFile: false),
            location: location
        )
    }

    /// The 16 `didSet { noteEditorReplaceAuthorityInputDidChange() }` inputs, each once
    /// through the façade and once on its container.
    func authorityInputMutations() throws -> [WindowStatePartitionAuthorityMutation] {
        let facade = try facadeAuthorityWrites()
        let container = windowAuthorityWrites().map { write in
            WindowStatePartitionAuthorityMutation(input: write.input, path: "container") {
                write.apply($0.windowState)
            }
        } + registryAuthorityWrites().map { write in
            WindowStatePartitionAuthorityMutation(input: write.input, path: "container") {
                write.apply($0.registry)
            }
        }
        precondition(facade.map(\.input) == container.map(\.input))
        return zip(facade, container).flatMap { [$0, $1] }
    }

    /// The four Replace authority inputs `WindowState` hooks, written on the container.
    func windowAuthorityWrites() -> [WindowStatePartitionInputWrite<WindowState>] {
        let url = location.fileURL
        return [
            .init(input: "currentDocument") { $0.currentDocument = DocumentSession(text: "container") },
            .init(input: "externalChangePrompt") { $0.externalChangePrompt = .init(fileURL: url) },
            .init(input: "missingFilePrompt") { $0.missingFilePrompt = .init(fileURL: url) },
            .init(input: "editorFocusRequestID") { $0.editorFocusRequestID += 1 },
        ]
    }

    /// The twelve Replace authority inputs `AppDocumentRegistry` hooks, written on the
    /// container. The keys belong to a session the façade writes never use.
    func registryAuthorityWrites() -> [WindowStatePartitionInputWrite<AppDocumentRegistry>] {
        let other = DocumentSession(text: "other")
        let otherID = ObjectIdentifier(other)
        let url = location.fileURL
        let installation = makeInstallation()
        let write = makeIndeterminateWrite()
        let reload = reloadTask(for: other)
        let inspection = inspectionTask(for: other)
        return [
            .init(input: "editorBindingInstallations") { $0.editorBindingInstallations[installation] = other },
            .init(input: "pendingEditorSourceInstallations") {
                $0.pendingEditorSourceInstallations[installation] = other
            },
            .init(input: "deferredExternalChangeResolutions") {
                $0.deferredExternalChangeResolutions[url] = .keepMine
            },
            .init(input: "externalReloadTasks") { $0.externalReloadTasks[otherID] = reload },
            .init(input: "externalDiskInspectionTasks") { $0.externalDiskInspectionTasks[otherID] = inspection },
            // A subscript write fires `didSet` even when it stores no new value.
            .init(input: "pendingExternalReloadApplications") {
                $0.pendingExternalReloadApplications[otherID] = nil
            },
            .init(input: "pendingExternalTexts") { $0.pendingExternalTexts[url] = "disk again" },
            .init(input: "pendingExternalFileVersions") { $0.pendingExternalFileVersions[url] = nil },
            .init(input: "detachedSessionURLs") { _ = $0.detachedSessionURLs.remove(url) },
            .init(input: "indeterminateSessionWrites") { $0.indeterminateSessionWrites[otherID] = write },
            .init(input: "workspaceMutationWriteFences") { _ = $0.workspaceMutationWriteFences.insert(otherID) },
            .init(input: "indeterminateWorkspaceMutationSessions") {
                _ = $0.indeterminateWorkspaceMutationSessions.insert(otherID)
            },
        ]
    }

    /// The same 16 inputs, written through `AppState`'s façade on its current session.
    private func facadeAuthorityWrites() throws -> [WindowStatePartitionAuthorityMutation] {
        let session = appState.currentDocument
        let sessionID = ObjectIdentifier(session)
        let url = location.fileURL
        let installation = makeInstallation()
        let version = try ObservedRetainedFileVersion(
            location: location,
            result: MarkdownFileStore().loadResult(at: location)
        )
        let write = makeIndeterminateWrite()
        let reload = reloadTask(for: session)
        let inspection = inspectionTask(for: session)
        func facade(
            _ input: String,
            _ apply: @escaping @MainActor (AppState) -> Void
        ) -> WindowStatePartitionAuthorityMutation {
            .init(input: input, path: "façade", apply: apply)
        }
        return [
            facade("currentDocument") { $0.currentDocument = DocumentSession(text: "façade") },
            facade("externalChangePrompt") { $0.externalChangePrompt = .init(fileURL: url) },
            facade("missingFilePrompt") { $0.missingFilePrompt = .init(fileURL: url) },
            // `private(set)` on the façade; `requestEditorFocus()` is its writer.
            facade("editorFocusRequestID") { $0.requestEditorFocus() },
            facade("editorBindingInstallations") { $0.editorBindingInstallations[installation] = session },
            facade("pendingEditorSourceInstallations") { $0.pendingEditorSourceInstallations[installation] = session },
            facade("deferredExternalChangeResolutions") { $0.deferredExternalChangeResolutions[url] = .reload },
            facade("externalReloadTasks") { $0.externalReloadTasks[sessionID] = reload },
            facade("externalDiskInspectionTasks") { $0.externalDiskInspectionTasks[sessionID] = inspection },
            facade("pendingExternalReloadApplications") { $0.pendingExternalReloadApplications[sessionID] = nil },
            facade("pendingExternalTexts") { $0.pendingExternalTexts[url] = "disk" },
            facade("pendingExternalFileVersions") { $0.pendingExternalFileVersions[url] = version },
            facade("detachedSessionURLs") { _ = $0.detachedSessionURLs.insert(url) },
            facade("indeterminateSessionWrites") { $0.indeterminateSessionWrites[sessionID] = write },
            facade("workspaceMutationWriteFences") { _ = $0.workspaceMutationWriteFences.insert(sessionID) },
            facade("indeterminateWorkspaceMutationSessions") {
                _ = $0.indeterminateWorkspaceMutationSessions.insert(sessionID)
            },
        ]
    }

    private func makeInstallation() -> EditorDocumentBindingInstallation {
        EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
    }

    private func makeIndeterminateWrite() -> WorkspaceIndeterminateFileWrite {
        WorkspaceIndeterminateFileWrite(reason: .durabilityFailed, preparedMetadata: nil, recoveryArtifact: .none)
    }

    private func reloadTask(for session: DocumentSession) -> ExternalReloadTask {
        ExternalReloadTask(
            token: UUID(),
            generation: 0,
            session: session,
            canonicalURL: location.fileURL,
            location: location,
            lifecycleGeneration: 0,
            sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
            diskEventGeneration: 0,
            intent: .reload,
            task: Task {}
        )
    }

    private func inspectionTask(for session: DocumentSession) -> ExternalDiskInspectionTask {
        ExternalDiskInspectionTask(
            token: UUID(),
            session: session,
            canonicalURL: location.fileURL,
            location: location,
            lifecycleGeneration: 0,
            diskEventGeneration: 0,
            sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
            task: Task {}
        )
    }
}
