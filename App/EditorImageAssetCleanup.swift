import Darwin
import Foundation
import WorkspaceKit

enum EditorImageAssetDiscardEvent: Equatable {
    case willRename(originalLeafName: String)
    case didRename(originalLeafName: String, recoveryLeafName: String)
    case didValidateRecovery(recoveryLeafName: String)
}

typealias EditorImageAssetDiscardEventHandler = @Sendable (
    EditorImageAssetDiscardEvent
) throws -> Void

typealias EditorImageAssetDirectorySynchronizer = (Int32) throws -> Void
typealias EditorImageAssetNamespaceInspector = (
    Int32,
    String
) -> EditorImageAssetNamespaceEntryInspection
typealias EditorImageAssetDescriptorLinkInspector = (
    Int32
) -> EditorImageAssetDescriptorLinkInspection

struct EditorImageAssetDiscardOutcome {
    var didChangeWorkspace = false
    var issues: [String] = []

    var userFacingIssue: EditorImageAssetDiscardIssue? {
        issues.isEmpty ? nil : EditorImageAssetDiscardIssue(details: issues)
    }
}

struct EditorImageAssetDiscardIssue: LocalizedError {
    let details: [String]

    var errorDescription: String? {
        "Plainsong preserved image data because it changed or could not be safely removed: " +
            details.joined(separator: "; ")
    }
}

func discardEditorImageAssets(
    _ assets: [CreatedEditorImageAsset],
    rootURL: URL,
    eventHandler: EditorImageAssetDiscardEventHandler? = nil
) -> EditorImageAssetDiscardOutcome {
    discardEditorImageAssets(
        assets,
        rootURL: rootURL,
        directorySynchronizer: synchronizeEditorImageAssetDirectory,
        namespaceInspector: inspectEditorImageAssetNamespaceEntry,
        descriptorLinkInspector: inspectEditorImageAssetDescriptorLinks,
        eventHandler: eventHandler
    )
}

func discardEditorImageAssets(
    _ assets: [CreatedEditorImageAsset],
    rootURL: URL,
    directorySynchronizer: EditorImageAssetDirectorySynchronizer,
    namespaceInspector: EditorImageAssetNamespaceInspector =
        inspectEditorImageAssetNamespaceEntry,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector =
        inspectEditorImageAssetDescriptorLinks,
    eventHandler: EditorImageAssetDiscardEventHandler? = nil
) -> EditorImageAssetDiscardOutcome {
    SecurityScopedAccess.withAccess(to: rootURL) {
        var outcome = EditorImageAssetDiscardOutcome()
        for asset in assets {
            guard asset.claimDiscard() else { continue }
            switch discardCreatedEditorImageAsset(
                asset,
                directorySynchronizer: directorySynchronizer,
                namespaceInspector: namespaceInspector,
                descriptorLinkInspector: descriptorLinkInspector,
                eventHandler: eventHandler
            ) {
            case .missing:
                continue
            case .workspaceChanged:
                outcome.didChangeWorkspace = true
            case let .preservedOriginal(location, reason):
                outcome.issues.append(
                    "asset preserved at \(location.userFacingDescription) (\(reason))"
                )
            case let .preservedRecovery(location, reason):
                outcome.didChangeWorkspace = true
                outcome.issues.append(
                    "asset preserved at recovery location \(location.userFacingDescription) " +
                        "(\(reason))"
                )
            case let .preservedArtifacts(artifacts, didChangeWorkspace):
                outcome.didChangeWorkspace = outcome.didChangeWorkspace || didChangeWorkspace
                for artifact in artifacts {
                    let qualifier = artifact.isRecovery ? " at recovery location" : ""
                    outcome.issues.append(
                        "asset preserved\(qualifier) " +
                            "\(artifact.location.userFacingDescription) " +
                            "(\(artifact.reason))"
                    )
                }
            }
        }
        return outcome
    }
}

enum EditorImageAssetPreservationValidation {
    case exact
    case changed
    case indeterminate(String)
}

enum EditorImageAssetAcquiredRecoveryInspection {
    case snapshot(EditorImageAssetNamespaceEntrySnapshot)
    case disposition(EditorImageAssetDiscardDisposition)
}

func inspectAcquiredEditorImageAssetRecovery(
    _ asset: CreatedEditorImageAsset,
    preservationName: String,
    namespaceInspector: EditorImageAssetNamespaceInspector,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetAcquiredRecoveryInspection {
    switch namespaceInspector(asset.directory.descriptor, preservationName) {
    case let .present(snapshot):
        return .snapshot(snapshot)

    case .missing:
        if let createdArtifact = preservedLinkedCreatedEditorImageAssetArtifact(
            asset,
            reason: "recovery entry disappeared before it could be inspected",
            isRecovery: true,
            descriptorLinkInspector: descriptorLinkInspector
        ) {
            return .disposition(
                .preservedArtifacts([createdArtifact], didChangeWorkspace: true)
            )
        }
        return .disposition(.workspaceChanged)

    case let .indeterminate(reason):
        var artifacts = [EditorImageAssetPreservedArtifact(
            location: EditorImageAssetPreservedLocation(
                currentPath: nil,
                identity: nil,
                leafNameHint: preservationName
            ),
            reason: "recovery entry could not be inspected: \(reason)",
            isRecovery: true
        )]
        if let createdArtifact = preservedLinkedCreatedEditorImageAssetArtifact(
            asset,
            reason: "created asset remains linked outside its published name",
            isRecovery: false,
            descriptorLinkInspector: descriptorLinkInspector
        ) {
            artifacts.append(createdArtifact)
        }
        return .disposition(
            .preservedArtifacts(artifacts, didChangeWorkspace: true)
        )
    }
}

func preservedUnsynchronizedEditorImageAssetDisposition(
    _ asset: CreatedEditorImageAsset,
    preservationName: String,
    reason: String,
    namespaceInspector: EditorImageAssetNamespaceInspector,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetDiscardDisposition {
    var artifacts = [EditorImageAssetPreservedArtifact(
        location: EditorImageAssetPreservedLocation(
            currentPath: nil,
            identity: nil,
            leafNameHint: preservationName
        ),
        reason: reason + "; the entry acquired by the recovery rename could not be rebound",
        isRecovery: true
    )]
    let currentNamespaceLocation: EditorImageAssetPreservedLocation?
    switch namespaceInspector(asset.directory.descriptor, preservationName) {
    case let .present(snapshot):
        let location = editorImageAssetPreservedLocationForNamespaceEntry(
            directoryDescriptor: asset.directory.descriptor,
            leafName: preservationName,
            fallbackIdentity: snapshot.identity
        )
        currentNamespaceLocation = location
        artifacts.append(EditorImageAssetPreservedArtifact(
            location: location,
            reason: "current recovery namespace occupant was observed after the durability " +
                "failure and is not proof of the entry acquired by rename",
            isRecovery: true
        ))

    case .missing:
        currentNamespaceLocation = nil

    case let .indeterminate(inspectionReason):
        let location = EditorImageAssetPreservedLocation(
            currentPath: nil,
            identity: nil,
            leafNameHint: preservationName
        )
        currentNamespaceLocation = location
        artifacts.append(EditorImageAssetPreservedArtifact(
            location: location,
            reason: "current recovery namespace occupant could not be inspected after the " +
                "durability failure: \(inspectionReason)",
            isRecovery: true
        ))
    }
    if let createdArtifact = preservedLinkedCreatedEditorImageAssetArtifact(
        asset,
        reason: "created asset remains linked outside its published name",
        isRecovery: false,
        descriptorLinkInspector: descriptorLinkInspector
    ), currentNamespaceLocation == nil
        || createdArtifact.location.identity != currentNamespaceLocation?.identity
        || createdArtifact.location.currentPath != currentNamespaceLocation?.currentPath
    {
        artifacts.append(createdArtifact)
    }
    return .preservedArtifacts(artifacts, didChangeWorkspace: true)
}

func addingUnknownAcquiredEditorImageAssetRecovery(
    to disposition: EditorImageAssetDiscardDisposition,
    preservationName: String
) -> EditorImageAssetDiscardDisposition {
    let unknownArtifact = EditorImageAssetPreservedArtifact(
        location: EditorImageAssetPreservedLocation(
            currentPath: nil,
            identity: nil,
            leafNameHint: preservationName
        ),
        reason: "the recovery rename cannot atomically prove which entry it acquired",
        isRecovery: true
    )

    switch disposition {
    case .missing, .workspaceChanged:
        return .preservedArtifacts([unknownArtifact], didChangeWorkspace: true)

    case let .preservedOriginal(location, reason):
        return .preservedArtifacts([
            unknownArtifact,
            EditorImageAssetPreservedArtifact(
                location: location,
                reason: reason,
                isRecovery: false
            ),
        ], didChangeWorkspace: true)

    case let .preservedRecovery(location, reason):
        return .preservedArtifacts([
            unknownArtifact,
            EditorImageAssetPreservedArtifact(
                location: location,
                reason: "post-rename observed artifact: \(reason)",
                isRecovery: true
            ),
        ], didChangeWorkspace: true)

    case let .preservedArtifacts(artifacts, _):
        let alreadyIncludesUnknownAcquired = artifacts.contains { artifact in
            artifact.location.currentPath == nil
                && artifact.location.identity == nil
                && artifact.location.leafNameHint == preservationName
                && artifact.reason.contains("entry acquired by the recovery rename")
        }
        return .preservedArtifacts(
            alreadyIncludesUnknownAcquired ? artifacts : [unknownArtifact] + artifacts,
            didChangeWorkspace: true
        )
    }
}

func validatePreservedEditorImageAsset(
    descriptor: Int32,
    expectedProof: EditorImageAssetContentProof,
    directoryDescriptor: Int32,
    preservationName: String
) -> EditorImageAssetPreservationValidation {
    do {
        let before = try editorImageAssetStableMetadata(descriptor: descriptor)
        guard before.identity == expectedProof.identity,
              before.byteCount == expectedProof.byteCount
        else {
            return .changed
        }
        let digest = try editorImageSHA256Digest(descriptor: descriptor)
        let after = try editorImageAssetStableMetadata(descriptor: descriptor)
        guard before == after else { return .indeterminate("asset changed while validating") }
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: directoryDescriptor,
            leafName: preservationName,
            expectedIdentity: after.identity
        )
        return digest == expectedProof.sha256Digest ? .exact : .changed
    } catch {
        return .indeterminate(error.localizedDescription)
    }
}

func editorImageAssetDiscardDidChangeWorkspace(
    _ disposition: EditorImageAssetDiscardDisposition
) -> Bool {
    switch disposition {
    case .missing, .preservedOriginal:
        false
    case .workspaceChanged, .preservedRecovery:
        true
    case let .preservedArtifacts(_, didChangeWorkspace):
        didChangeWorkspace
    }
}
