import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKitContracts
import SwiftUI
import UIKit
import WorkspaceCore
import WorkspaceKitIOS

// MARK: - Observation token

@MainActor
final class FakeObservation: IOSObservation {
    private(set) var isCancelled = false
    var onCancel: (() -> Void)?

    init(onCancel: (() -> Void)? = nil) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
    }
}

// MARK: - Scene facade (13's production stand-in)

@MainActor
final class FakeSceneFacade: IOSAppSceneControlling {
    var snapshot: IOSAppSceneSnapshot
    var capabilities: IOSSceneCapabilities

    var setCommandFocusCalls: [(focused: Bool, identity: IOSDocumentIdentity, bindingID: UUID)] = []
    var commandFocusResult = true
    var openedURLs: [(url: URL, scope: IOSWorkspaceScope)] = []
    var onOpen: ((URL, IOSWorkspaceScope) async throws -> Void)?
    var createdAt: [IOSFileLocation] = []
    var saveCalls = 0
    var resolvedExternal: [IOSExternalResolution] = []
    var flushCount = 0

    private var handlers: [@MainActor (IOSAppSceneSnapshot) -> Void] = []

    init(
        snapshot: IOSAppSceneSnapshot = IOSAppSceneSnapshot(
            document: nil,
            documentState: nil,
            workspace: nil,
            unavailableReason: nil
        ),
        capabilities: IOSSceneCapabilities
    ) {
        self.snapshot = snapshot
        self.capabilities = capabilities
    }

    /// Simulate a facade-originated snapshot publish (open/save/conflict…).
    func emit(_ snapshot: IOSAppSceneSnapshot) {
        self.snapshot = snapshot
        for handler in handlers {
            handler(snapshot)
        }
    }

    func setCommandFocus(_ focused: Bool, expected: IOSDocumentIdentity, bindingID: UUID) -> Bool {
        setCommandFocusCalls.append((focused, expected, bindingID))
        return commandFocusResult
    }

    func openSelectedURL(_ url: URL, scope: IOSWorkspaceScope) async throws {
        openedURLs.append((url, scope))
        try await onOpen?(url, scope)
    }

    func createDocument(at location: IOSFileLocation) async throws {
        createdAt.append(location)
    }

    func saveCurrentDocument() async throws -> IOSSaveAcknowledgement {
        saveCalls += 1
        guard let stored = snapshot.document else {
            throw IOSDocumentFailure.unavailable
        }
        return IOSSaveAcknowledgement(
            operationID: UUID(),
            revision: stored.revision,
            savedText: stored.document.text,
            location: stored.location
        )
    }

    func resolveExternal(_ choice: IOSExternalResolution) async throws {
        resolvedExternal.append(choice)
    }

    func observe(_ handler: @escaping @MainActor (IOSAppSceneSnapshot) -> Void) -> any IOSObservation {
        handlers.append(handler)
        return FakeObservation()
    }

    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        flushCount += 1
        return []
    }
}

// MARK: - Editor binding (04's native stand-in)

/// Records every mutation the shell could trigger; `apply` honors a queued
/// refusal so read-only/focus refusals can be probed through the contract.
@MainActor
final class FakeEditorBinding: IOSSourceEditorBinding {
    let bindingID = UUID()
    let identity: IOSDocumentIdentity
    let session: DocumentSession

    var revision = 0
    var selection: NSRange
    var visibleRange: NSRange
    var selectionGeneration: UInt64 = 1
    var accessGeneration: UInt64 = 1
    var hasMarkedText = false
    var canWrite: Bool
    var isFocused: Bool

    var appliedEdits: [IOSAuthorizedEdit] = []
    var nextRefusal: IOSEditRefusal?
    var undoCount = 0
    var redoCount = 0
    var attachCount = 0
    var detachCalls: [(identity: IOSDocumentIdentity, bindingID: UUID)] = []
    var accessUpdateCount = 0
    var commandFocusUpdates: [(identity: IOSDocumentIdentity, bindingID: UUID, focused: Bool)] = []
    var revealCalls: [(range: NSRange, expected: IOSDocumentRevision)] = []
    var revealResult = true

    private var handlers: [@MainActor (IOSSourceEditorEvent) -> Void] = []

    init(
        text: String = "# hello\n",
        canWrite: Bool = true,
        isFocused: Bool = true,
        selection: NSRange = NSRange(location: 3, length: 0),
        visibleRange: NSRange = NSRange(location: 0, length: 8),
        identity: IOSDocumentIdentity = IOSDocumentIdentity(rawValue: UUID())
    ) {
        session = DocumentSession(text: text)
        self.identity = identity
        self.canWrite = canWrite
        self.isFocused = isFocused
        self.selection = selection
        self.visibleRange = visibleRange
    }

    func emit(_ event: IOSSourceEditorEvent) {
        for handler in handlers {
            handler(event)
        }
    }

    func emitSnapshot() {
        if let snapshot = captureSnapshot() {
            emit(.snapshotChanged(snapshot))
        }
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        IOSSourceEditorSnapshot(
            bindingID: bindingID,
            revision: IOSDocumentRevision(documentID: identity, version: revision),
            document: session.snapshot,
            selection: selection,
            visibleRange: visibleRange,
            selectionGeneration: selectionGeneration,
            accessGeneration: accessGeneration,
            hasMarkedText: hasMarkedText,
            canWrite: canWrite,
            isFocused: isFocused
        )
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        appliedEdits.append(edit)
        if let refusal = nextRefusal {
            return .refused(refusal)
        }
        // Apply the authorized range replacement (UTF-16 ranges, per contract).
        let newText = (session.text as NSString).replacingCharacters(
            in: edit.result.replacementRange,
            with: edit.result.replacementString
        )
        session.replaceTextFromAuthorizedEditor(newText)
        revision += 1
        emitSnapshot()
        return .applied(IOSDocumentRevision(documentID: identity, version: revision))
    }

    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool {
        revealCalls.append((range, expected))
        return revealResult
    }

    func undo() {
        undoCount += 1
    }

    func redo() {
        redoCount += 1
    }

    func attach(_: IOSSourceEditorDocumentBinding) {
        attachCount += 1
    }

    func detach(expected identity: IOSDocumentIdentity, bindingID: UUID) {
        detachCalls.append((identity, bindingID))
        emit(.detached(documentID: identity, bindingID: bindingID))
    }

    func updateAccess(for _: IOSDocumentIdentity, bindingID _: UUID, generation: UInt64, canWrite: Bool) {
        accessUpdateCount += 1
        accessGeneration = generation
        self.canWrite = canWrite
        emitSnapshot()
    }

    func updateCommandFocus(for identity: IOSDocumentIdentity, bindingID: UUID, isFocused: Bool) {
        commandFocusUpdates.append((identity, bindingID, isFocused))
        self.isFocused = isFocused
        emitSnapshot()
    }

    func installExternalReload(_: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        .deferred
    }

    func observe(_ handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void) -> any IOSObservation {
        handlers.append(handler)
        return FakeObservation()
    }
}

// MARK: - Preview controller (07's stand-in)

@MainActor
final class FakePreviewController: IOSPreviewControlling {
    var renderCalls: [(snapshot: DocumentSnapshot, identity: IOSDocumentIdentity)] = []
    var remoteImagesAllowed: Bool?
    var scrolledLines: [Int] = []
    var invalidateCount = 0
    private var handlers: [@MainActor (IOSPreviewEvent) -> Void] = []

    func render(_ snapshot: DocumentSnapshot, identity: IOSDocumentIdentity,
                assetAccess _: PreviewAssetAccessContext?)
    {
        renderCalls.append((snapshot, identity))
    }

    func setRemoteImagesAllowed(_ allowed: Bool) {
        remoteImagesAllowed = allowed
    }

    func scrollToLine(_ line: Int) {
        scrolledLines.append(line)
    }

    func invalidate() {
        invalidateCount += 1
    }

    func observe(_ handler: @escaping @MainActor (IOSPreviewEvent) -> Void) -> any IOSObservation {
        handlers.append(handler)
        return FakeObservation()
    }
}

// MARK: - Authoring provider (08's stand-in)

@MainActor
final class FakeAuthoringProvider: IOSAuthoringActionProviding {
    var actions: [IOSAuthoringAction]
    /// `(actionID, editor)` pairs — identity assertions use ObjectIdentifier.
    private(set) var performed: [(action: IOSAuthoringActionID, editor: ObjectIdentifier)] = []
    var isEnabledOverride: ((IOSAuthoringActionID, IOSSourceEditorSnapshot?) -> Bool)?

    init(actions: [IOSAuthoringAction]? = nil) {
        self.actions = actions ?? [
            IOSAuthoringAction(
                id: .bold, title: "Bold", accessibilityLabel: "Bold",
                placement: .toolbar, keyboardInput: "b", keyboardModifiers: .command
            ),
            IOSAuthoringAction(
                id: .italic, title: "Italic", accessibilityLabel: "Italic",
                placement: .toolbar, keyboardInput: "i", keyboardModifiers: .command
            ),
            IOSAuthoringAction(
                id: .heading(2), title: "Heading", accessibilityLabel: "Heading level 2",
                placement: .formatMenu, keyboardInput: nil, keyboardModifiers: []
            ),
        ]
    }

    func isEnabled(_ action: IOSAuthoringActionID, snapshot: IOSSourceEditorSnapshot?) -> Bool {
        if let isEnabledOverride {
            return isEnabledOverride(action, snapshot)
        }
        // Provider rule: the action only lights up for a focused, writable editor.
        guard let snapshot else { return false }
        return snapshot.isFocused && snapshot.canWrite
    }

    func perform(_ action: IOSAuthoringActionID, using editor: any IOSSourceEditorControlling) {
        performed.append((action, ObjectIdentifier(editor)))
    }
}

// MARK: - Image insertion (09's stand-in)

@MainActor
final class FakeImageInserter: IOSImageInsertionControlling {
    var capturedContexts: [IOSImageInsertionContext] = []
    var insertCalls = 0
    var cancelledOperationIDs: [UUID] = []
    var nextOutcome: IOSImageInsertionOutcome = .cancelled

    func captureContext(
        using editor: any IOSSourceEditorControlling,
        destination: IOSFileLocation,
        grant: IOSWorkspaceGrant
    ) -> IOSImageInsertionContext? {
        guard let snapshot = editor.captureSnapshot() else { return nil }
        let context = IOSImageInsertionContext(
            operationID: UUID(),
            editor: snapshot,
            destination: destination,
            grant: grant
        )
        capturedContexts.append(context)
        return context
    }

    func insert(
        bytes _: Data,
        contentType _: String,
        preferredFilename _: String,
        context _: IOSImageInsertionContext,
        using _: any IOSSourceEditorControlling
    ) async -> IOSImageInsertionOutcome {
        insertCalls += 1
        return nextOutcome
    }

    func cancel(operationID: UUID) {
        cancelledOperationIDs.append(operationID)
    }
}

// MARK: - Fixture builders

/// `DocumentSession` is MainActor-isolated; fixtures only run inside
/// @MainActor tests anyway.
@MainActor
enum ShellFixtures {
    static let workspaceID = IOSWorkspaceIdentity(rawValue: UUID())

    static func location(
        _ relativePath: String,
        accessGeneration: UInt64 = 1
    ) -> IOSFileLocation {
        IOSFileLocation(
            workspaceID: workspaceID,
            accessGeneration: accessGeneration,
            relativePath: relativePath,
            fileURL: URL(fileURLWithPath: "/tmp/workspace/\(relativePath)"),
            resourceID: nil
        )
    }

    static func entry(
        _ path: String,
        kind: IOSWorkspaceEntry.Kind = .document(.markdown),
        availability: IOSFileAvailability = .available(canWrite: true),
        children: [IOSWorkspaceEntry] = []
    ) -> IOSWorkspaceEntry {
        IOSWorkspaceEntry(
            id: UUID(),
            location: location(path),
            kind: kind,
            availability: availability,
            children: children
        )
    }

    static func storedDocument(
        text: String = "# doc\n",
        state: IOSDocumentState = .ready(canWrite: true, accessGeneration: 1),
        path: String = "post.md",
        isDirty: Bool = false,
        fileKind: FileKind = .markdown
    ) -> IOSStoredDocumentSnapshot {
        let session = DocumentSession(
            text: text,
            url: URL(fileURLWithPath: "/tmp/workspace/\(path)"),
            fileKind: fileKind,
            isDirty: isDirty
        )
        return IOSStoredDocumentSnapshot(
            revision: IOSDocumentRevision(
                documentID: IOSDocumentIdentity(rawValue: UUID()),
                version: session.version
            ),
            document: session.snapshot,
            location: location(path),
            state: state
        )
    }

    static func workspace(entries: [IOSWorkspaceEntry]) -> IOSWorkspaceSnapshot {
        IOSWorkspaceSnapshot(
            workspaceID: workspaceID,
            accessGeneration: 1,
            requestID: UUID(),
            entries: entries
        )
    }

    static func grant(scope: IOSWorkspaceScope = .directory) -> IOSWorkspaceGrant {
        IOSWorkspaceGrant(
            workspaceID: workspaceID,
            rootURL: URL(fileURLWithPath: "/tmp/workspace"),
            accessGeneration: 1,
            scope: scope
        )
    }

    /// A ready-document scene snapshot with an optional workspace.
    static func sceneSnapshot(
        document: IOSStoredDocumentSnapshot? = nil,
        workspace: IOSWorkspaceSnapshot? = nil,
        unavailableReason: String? = nil
    ) -> IOSAppSceneSnapshot {
        IOSAppSceneSnapshot(
            document: document,
            documentState: document?.state,
            workspace: workspace,
            unavailableReason: unavailableReason
        )
    }
}
