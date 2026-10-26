import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// Per-file registry forwarding façade (`docs/window-state-gates.md` §3.2, Windows PR B1):
/// editor bindings and writers, external-change state, the session cache and LRU, ownership
/// proofs, quarantine, and namespace fences. Each property keeps the name, type, and access
/// level it had as an `AppState` stored property. Settable properties forward with `_modify`
/// (see `AppState+WindowStateForwarding.swift`), so the registry's Replace authority `didSet`
/// hooks fire exactly once per mutation, as they did on `AppState`.
@MainActor
extension AppState {
    var editorDocumentBindingIDs: [ObjectIdentifier: EditorDocumentBindingID] {
        get { registry.editorDocumentBindingIDs }
        _modify { yield &registry.editorDocumentBindingIDs }
    }

    var editorDocumentBindingSessions: [EditorDocumentBindingID: DocumentSession] {
        get { registry.editorDocumentBindingSessions }
        _modify { yield &registry.editorDocumentBindingSessions }
    }

    var editorBindingInstallations: [EditorDocumentBindingInstallation: DocumentSession] {
        get { registry.editorBindingInstallations }
        _modify { yield &registry.editorBindingInstallations }
    }

    var editorWriterInstallations: [ObjectIdentifier: EditorDocumentBindingInstallation] {
        get { registry.editorWriterInstallations }
        _modify { yield &registry.editorWriterInstallations }
    }

    var pendingEditorSourceInstallations: [EditorDocumentBindingInstallation: DocumentSession] {
        get { registry.pendingEditorSourceInstallations }
        _modify { yield &registry.pendingEditorSourceInstallations }
    }

    var editorDocumentSourceFullComparisonCounts: [EditorDocumentSourceFullComparisonKind: Int] {
        get { registry.editorDocumentSourceFullComparisonCounts }
        _modify { yield &registry.editorDocumentSourceFullComparisonCounts }
    }

    var editorDocumentSourceSynchronizers: [EditorDocumentBindingInstallation: EditorDocumentSourceSynchronizer] {
        get { registry.editorDocumentSourceSynchronizers }
        _modify { yield &registry.editorDocumentSourceSynchronizers }
    }

    var deferredExternalChangeResolutions: [URL: DeferredExternalChangeResolution] {
        get { registry.deferredExternalChangeResolutions }
        _modify { yield &registry.deferredExternalChangeResolutions }
    }

    var externalResolutionIntentCaptures: [URL: ExternalResolutionIntentCapture] {
        get { registry.externalResolutionIntentCaptures }
        _modify { yield &registry.externalResolutionIntentCaptures }
    }

    var externalReloadTasks: [ObjectIdentifier: ExternalReloadTask] {
        get { registry.externalReloadTasks }
        _modify { yield &registry.externalReloadTasks }
    }

    var externalDiskInspectionTasks: [ObjectIdentifier: ExternalDiskInspectionTask] {
        get { registry.externalDiskInspectionTasks }
        _modify { yield &registry.externalDiskInspectionTasks }
    }

    var pendingExternalReloadApplications: [ObjectIdentifier: PendingExternalReloadApplication] {
        get { registry.pendingExternalReloadApplications }
        _modify { yield &registry.pendingExternalReloadApplications }
    }

    var nextExternalReloadGeneration: UInt64 {
        get { registry.nextExternalReloadGeneration }
        _modify { yield &registry.nextExternalReloadGeneration }
    }

    var externalDiskEventGenerations: [ObjectIdentifier: UInt64] {
        get { registry.externalDiskEventGenerations }
        _modify { yield &registry.externalDiskEventGenerations }
    }

    var retiredEditorDocumentSessions: [URL: RetiredEditorDocumentSession] {
        get { registry.retiredEditorDocumentSessions }
        _modify { yield &registry.retiredEditorDocumentSessions }
    }

    var sessionCache: [URL: DocumentSession] {
        get { registry.sessionCache }
        _modify { yield &registry.sessionCache }
    }

    var sessionLifecycleGenerations: [ObjectIdentifier: UInt64] {
        get { registry.sessionLifecycleGenerations }
        _modify { yield &registry.sessionLifecycleGenerations }
    }

    var sessionPolicy: WorkspaceSessionLRUPolicy {
        get { registry.sessionPolicy }
        _modify { yield &registry.sessionPolicy }
    }

    var lastKnownDiskHashes: [URL: String] {
        get { registry.lastKnownDiskHashes }
        _modify { yield &registry.lastKnownDiskHashes }
    }

    var lastKnownDiskModificationDates: [URL: Date] {
        get { registry.lastKnownDiskModificationDates }
        _modify { yield &registry.lastKnownDiskModificationDates }
    }

    var pendingExternalTexts: [URL: String] {
        get { registry.pendingExternalTexts }
        _modify { yield &registry.pendingExternalTexts }
    }

    var pendingExternalFileVersions: [URL: ObservedRetainedFileVersion] {
        get { registry.pendingExternalFileVersions }
        _modify { yield &registry.pendingExternalFileVersions }
    }

    var detachedSessionURLs: Set<URL> {
        get { registry.detachedSessionURLs }
        _modify { yield &registry.detachedSessionURLs }
    }

    var anchoredSessionFileBindings: [ObjectIdentifier: AnchoredWorkspaceSessionFileBinding] {
        get { registry.anchoredSessionFileBindings }
        _modify { yield &registry.anchoredSessionFileBindings }
    }

    var unanchoredManagedSessionOwnershipProofs: [ObjectIdentifier: UnanchoredManagedSessionOwnershipProof] {
        get { registry.unanchoredManagedSessionOwnershipProofs }
        _modify { yield &registry.unanchoredManagedSessionOwnershipProofs }
    }

    var editorImageAssetDocumentAuthorities: [ObjectIdentifier: RetainedEditorImageAssetDocumentAuthority] {
        get { registry.editorImageAssetDocumentAuthorities }
        _modify { yield &registry.editorImageAssetDocumentAuthorities }
    }

    var indeterminateSessionWrites: [ObjectIdentifier: WorkspaceIndeterminateFileWrite] {
        get { registry.indeterminateSessionWrites }
        _modify { yield &registry.indeterminateSessionWrites }
    }

    var indeterminateSessionWriteContexts: [ObjectIdentifier: IndeterminateSessionWriteContext] {
        get { registry.indeterminateSessionWriteContexts }
        _modify { yield &registry.indeterminateSessionWriteContexts }
    }

    var workspaceMutationWriteFences: Set<ObjectIdentifier> {
        get { registry.workspaceMutationWriteFences }
        _modify { yield &registry.workspaceMutationWriteFences }
    }

    var workspaceMutationNamespaceDepth: Int {
        get { registry.workspaceMutationNamespaceDepth }
        _modify { yield &registry.workspaceMutationNamespaceDepth }
    }

    var indeterminateWorkspaceMutationSessions: Set<ObjectIdentifier> {
        get { registry.indeterminateWorkspaceMutationSessions }
        _modify { yield &registry.indeterminateWorkspaceMutationSessions }
    }
}
