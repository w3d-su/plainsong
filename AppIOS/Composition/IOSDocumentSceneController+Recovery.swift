import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

/// An immutable proposal, never authority to write the recovery record's old path.
@MainActor
struct IOSRecoveryRestoreCapture {
    let record: IOSRecoveryRecord
    let epoch: UInt64
    let session: DocumentSession?
    let identity: IOSDocumentIdentity?
    let bindingID: UUID?
    let editorGeneration: UInt64?
    let version: Int?
    let source: String?
    let location: IOSFileLocation?
    let grant: IOSWorkspaceGrant?
    let grantWasCurrent: Bool
    let destinationID = UUID()

    var filename: String {
        let path = String(data: record.relativePathUTF8, encoding: .utf8) ?? ""
        let validPath = WorkspaceRelativePath(spelling: path) != nil
        let leaf = (validPath ? (path as NSString).lastPathComponent : "") as NSString
        let suffix = leaf.pathExtension.lowercased() == "mdx" ? "mdx" : "md"
        // Display metadata suggests a new leaf only; it grants no path authority.
        // Bound UTF-8 bytes, not Character count, leaving space below NAME_MAX
        // for the recovery marker, issuance suffix and file extension.
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var stem = ""
        var byteCount = 0
        for character in leaf.deletingPathExtension {
            let part = String(character)
            guard !part.unicodeScalars.contains(where: { forbidden.contains($0) }) else { continue }
            guard byteCount + part.utf8.count <= 180 else { break }
            stem.append(character)
            byteCount += part.utf8.count
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = stem.isEmpty ? "Recovered" : "\(stem)-Recovered"
        return "\(prefix)-\(destinationID.uuidString.prefix(8).lowercased()).\(suffix)"
    }
}

/// The original writer safely closed before destination creation failed. This
/// is distinct from an early refusal that preserves the installed document.
struct IOSRecoveryRestoreFailure: Error {
    let cause: Error
    let previousDocumentClosed: Bool
}

/// The file and admitted writer already exist; only the Files readback failed.
struct IOSRecoveryCreatedFileRefreshFailure: Error {
    let cause: Error
}

extension IOSDocumentSceneController {
    func captureRecoveryRestore(_ record: IOSRecoveryRecord) throws -> IOSRecoveryRestoreCapture {
        guard !transitioning, !isShuttingDown, !isDisposed,
              editor.captureSnapshot()?.hasMarkedText != true else { throw IOSDocumentFailure.unavailable }
        let snapshot = editor.captureSnapshot()
        if let handle {
            guard snapshot?.bindingID == bindingID, snapshot?.revision.documentID == handle.identity else {
                throw IOSDocumentFailure.documentChanged
            }
        }
        return IOSRecoveryRestoreCapture(
            record: record, epoch: recoveryEpoch, session: handle?.session,
            identity: handle?.identity, bindingID: bindingID,
            editorGeneration: handle == nil ? nil : snapshot?.accessGeneration,
            version: handle?.session.version, source: handle?.session.text,
            location: handle?.location, grant: currentGrant, grantWasCurrent: grantIsCurrent
        )
    }

    /// Reads the selected draft again, safely closes the old writer, then creates
    /// a different file through the same store. The recovery record is retained.
    func restoreRecovery(
        _ capture: IOSRecoveryRestoreCapture,
        in folder: URL,
        loadRecord: @MainActor (UUID) async throws -> IOSRecoveryRecord,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        try validateRecoveryOrigin(capture, epoch: capture.epoch, afterClose: false, isCurrent: isCurrent)
        try beginTransition()
        let epoch = recoveryEpoch
        updateEditorAccess()
        defer { finishTransition() }

        var destination: IOSWorkspaceGrant?
        var adoptedDestination = false
        defer {
            if !adoptedDestination, let destination {
                _ = workspace.invalidate(destination.workspaceID)
            }
        }
        let record = try await loadRecord(capture.record.recordID)
        try validateRecoveryOrigin(capture, epoch: epoch, afterClose: false, isCurrent: isCurrent)
        guard record == capture.record,
              ExactSourceText.matches(record.source, capture.record.source),
              ExactSourceText.matches(record.baseline, capture.record.baseline)
        else { throw IOSDocumentFailure.sourceChanged }

        let grant = try await openDestinationFolder(folder)
        destination = grant
        try validateRecoveryOrigin(capture, epoch: epoch, afterClose: false, isCurrent: isCurrent)
        let tree = try await workspace.refresh(grant)
        try validateRecoveryOrigin(capture, epoch: epoch, afterClose: false, isCurrent: isCurrent)
        let location = try recoveryDestination(capture, grant: grant, tree: tree)
        // A synchronous lease admission proves the provisional grant is live.
        let probe = try workspace.acquireLease(for: grant)
        probe.release()
        try await closeCurrent()
        try validateRecoveryOrigin(capture, epoch: epoch, afterClose: true, isCurrent: isCurrent)

        // No suspension between final checks, replacing the grant and admitting
        // the new writer. install retains any late-revoked returned handle.
        try adoptCurrentGrant(grant, snapshot: tree)
        adoptedDestination = true
        do {
            try await install(location, initialText: record.source)
            guard isCurrent(), recoveryEpoch == epoch, !isShuttingDown, !isDisposed else {
                throw IOSDocumentFailure.documentChanged
            }
            // The collision check used a pre-create snapshot. Read the destination
            // again while this transition owns the writer so Files includes the
            // restored leaf even when the provider emits no watcher notification.
            try await refreshCreatedRecoveryFile()
            guard isCurrent(), recoveryEpoch == epoch, !isShuttingDown, !isDisposed else {
                throw IOSDocumentFailure.documentChanged
            }
        } catch {
            if handle == nil {
                releaseCurrentGrant()
                if capture.grant != nil || capture.identity != nil {
                    throw IOSRecoveryRestoreFailure(cause: error, previousDocumentClosed: capture.identity != nil)
                }
            }
            throw error
        }
    }

    private func refreshCreatedRecoveryFile() async throws {
        do {
            try await refreshWorkspace()
        } catch {
            throw IOSRecoveryCreatedFileRefreshFailure(cause: error)
        }
    }

    private func validateRecoveryOrigin(
        _ capture: IOSRecoveryRestoreCapture,
        epoch: UInt64,
        afterClose: Bool,
        isCurrent: @MainActor () -> Bool
    ) throws {
        guard isCurrent(), recoveryEpoch == epoch, !isShuttingDown, !isDisposed else {
            throw IOSDocumentFailure.documentChanged
        }
        if let session = capture.session {
            guard session.version == capture.version,
                  capture.source.map({ ExactSourceText.matches(session.text, $0) }) == true
            else { throw IOSDocumentFailure.sourceChanged }
        }
        if afterClose {
            guard handle == nil, bindingID == nil, ownedTicket == nil, admission.active == nil else {
                throw IOSDocumentFailure.documentChanged
            }
        } else {
            guard handle?.identity == capture.identity, bindingID == capture.bindingID,
                  handle?.session === capture.session else { throw IOSDocumentFailure.documentChanged }
            if let identity = capture.identity {
                let snapshot = editor.captureSnapshot()
                guard snapshot?.bindingID == capture.bindingID,
                      snapshot?.revision.documentID == identity,
                      snapshot?.revision.version == capture.version,
                      snapshot?.accessGeneration == capture.editorGeneration
                else { throw IOSDocumentFailure.documentChanged }
            }
            if let location = capture.location, let current = handle?.location {
                guard Self.sameLocation(location, current) else { throw IOSDocumentFailure.documentChanged }
            }
        }
        try validateRecoveryGrant(capture)
    }

    private func validateRecoveryGrant(_ capture: IOSRecoveryRestoreCapture) throws {
        guard grantIsCurrent == capture.grantWasCurrent,
              currentGrant?.workspaceID == capture.grant?.workspaceID,
              currentGrant?.accessGeneration == capture.grant?.accessGeneration,
              currentGrant?.scope == capture.grant?.scope,
              currentGrant.map({ Data($0.rootURL.path(percentEncoded: false).utf8) }) ==
              capture.grant.map({ Data($0.rootURL.path(percentEncoded: false).utf8) })
        else { throw IOSWorkspaceFailure.grantChanged }
    }

    private func recoveryDestination(_ capture: IOSRecoveryRestoreCapture, grant: IOSWorkspaceGrant,
                                     tree: IOSWorkspaceSnapshot) throws -> IOSFileLocation
    {
        guard tree.workspaceID == grant.workspaceID, tree.accessGeneration == grant.accessGeneration else {
            throw IOSWorkspaceFailure.grantChanged
        }
        let location = IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
            relativePath: capture.filename, fileURL: grant.rootURL.appendingPathComponent(capture.filename),
            resourceID: nil
        )
        guard !Self.flatten(tree.entries).contains(where: {
            $0.location.relativePath.utf8.elementsEqual(location.relativePath.utf8)
        }) else { throw IOSDocumentFailure.access(.alreadyExists) }
        return location
    }
}
