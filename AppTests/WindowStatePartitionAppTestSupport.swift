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
        let session = appState.currentDocument
        let sessionID = ObjectIdentifier(session)
        let other = DocumentSession(text: "other")
        let otherID = ObjectIdentifier(other)
        let url = location.fileURL
        let installation = EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
        let version = try ObservedRetainedFileVersion(
            location: location,
            result: MarkdownFileStore().loadResult(at: location)
        )
        let write = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        let reload = reloadTask(for: session)
        let otherReload = reloadTask(for: other)
        let inspection = inspectionTask(for: session)
        let otherInspection = inspectionTask(for: other)
        func pair(
            _ input: String,
            facade: @escaping @MainActor (AppState) -> Void,
            container: @escaping @MainActor (AppState) -> Void
        ) -> [WindowStatePartitionAuthorityMutation] {
            [.init(input: input, path: "façade", apply: facade),
             .init(input: input, path: "container", apply: container)]
        }
        return [
            pair("currentDocument",
                 facade: { $0.currentDocument = DocumentSession(text: "façade") },
                 container: { $0.windowState.currentDocument = DocumentSession(text: "container") }),
            pair("externalChangePrompt",
                 facade: { $0.externalChangePrompt = .init(fileURL: url) },
                 container: { $0.windowState.externalChangePrompt = .init(fileURL: url) }),
            pair("missingFilePrompt",
                 facade: { $0.missingFilePrompt = .init(fileURL: url) },
                 container: { $0.windowState.missingFilePrompt = .init(fileURL: url) }),
            // `private(set)` on the façade; `requestEditorFocus()` is its writer.
            pair("editorFocusRequestID",
                 facade: { $0.requestEditorFocus() },
                 container: { $0.windowState.editorFocusRequestID += 1 }),
            pair("editorBindingInstallations",
                 facade: { $0.editorBindingInstallations[installation] = session },
                 container: { $0.registry.editorBindingInstallations[installation] = other }),
            pair("pendingEditorSourceInstallations",
                 facade: { $0.pendingEditorSourceInstallations[installation] = session },
                 container: { $0.registry.pendingEditorSourceInstallations[installation] = other }),
            pair("deferredExternalChangeResolutions",
                 facade: { $0.deferredExternalChangeResolutions[url] = .reload },
                 container: { $0.registry.deferredExternalChangeResolutions[url] = .keepMine }),
            pair("externalReloadTasks",
                 facade: { $0.externalReloadTasks[sessionID] = reload },
                 container: { $0.registry.externalReloadTasks[otherID] = otherReload }),
            pair("externalDiskInspectionTasks",
                 facade: { $0.externalDiskInspectionTasks[sessionID] = inspection },
                 container: { $0.registry.externalDiskInspectionTasks[otherID] = otherInspection }),
            // A subscript write fires `didSet` even when it stores no new value.
            pair("pendingExternalReloadApplications",
                 facade: { $0.pendingExternalReloadApplications[sessionID] = nil },
                 container: { $0.registry.pendingExternalReloadApplications[otherID] = nil }),
            pair("pendingExternalTexts",
                 facade: { $0.pendingExternalTexts[url] = "disk" },
                 container: { $0.registry.pendingExternalTexts[url] = "disk again" }),
            pair("pendingExternalFileVersions",
                 facade: { $0.pendingExternalFileVersions[url] = version },
                 container: { $0.registry.pendingExternalFileVersions[url] = nil }),
            pair("detachedSessionURLs",
                 facade: { _ = $0.detachedSessionURLs.insert(url) },
                 container: { _ = $0.registry.detachedSessionURLs.remove(url) }),
            pair("indeterminateSessionWrites",
                 facade: { $0.indeterminateSessionWrites[sessionID] = write },
                 container: { $0.registry.indeterminateSessionWrites[otherID] = write }),
            pair("workspaceMutationWriteFences",
                 facade: { _ = $0.workspaceMutationWriteFences.insert(sessionID) },
                 container: { _ = $0.registry.workspaceMutationWriteFences.insert(otherID) }),
            pair("indeterminateWorkspaceMutationSessions",
                 facade: { _ = $0.indeterminateWorkspaceMutationSessions.insert(sessionID) },
                 container: { _ = $0.registry.indeterminateWorkspaceMutationSessions.insert(otherID) }),
        ].flatMap { $0 }
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
