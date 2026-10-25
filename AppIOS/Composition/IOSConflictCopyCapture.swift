import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

struct IOSConflictCopyDraft: Identifiable, Sendable {
    let id: UUID
    let suggestedFilename: String
}

struct IOSConflictCopyPickerRequest: Identifiable, Sendable {
    let id: UUID
    let draftID: UUID
    let filename: String
}

struct IOSConflictCopyNotice: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

enum IOSConflictCopyFailure: Error, Equatable, Sendable {
    case originChanged
    case sourceChanged
    case destinationChanged
    case invalidFilename
    case alreadyExists
    case unavailable
    case cancelled
}

enum IOSConflictCopyOutcome: Equatable, Sendable {
    case saved(filename: String)
    case refused(IOSConflictCopyFailure, copyMayExist: Bool)
    case cancelled
}

/// Captured source state is evidence for reading the retained in-memory source,
/// never authority to read or overwrite the unavailable original location.
enum IOSCopyOriginState: Equatable {
    case conflict(UInt64, UUID?, UUID?, IOSDocumentRevision?)
    case unavailable(UInt64, IOSDocumentFailure)

    init?(_ state: IOSDocumentState?) {
        switch state {
        case let .conflict(generation, recovery):
            self = .conflict(generation, recovery?.recordID, recovery?.operationID, recovery?.revision)
        case let .unavailable(generation, reason):
            self = .unavailable(generation, reason)
        default: return nil
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }
}

/// Immutable authority captured before presenting either sheet. This is not an
/// editable source or a second writer; the store still captures its own bytes.
@MainActor
struct IOSConflictCopyOrigin {
    let draftID: UUID
    let handle: IOSDocumentHandle
    let bindingID: UUID
    let revision: IOSDocumentRevision
    let source: String
    let isDirty: Bool
    let editorGeneration: UInt64
    let grant: IOSWorkspaceGrant
    let grantWasCurrent: Bool
    let state: IOSCopyOriginState

    init(controller: IOSDocumentSceneController, draftID: UUID) throws {
        guard !controller.transitioning, !controller.isDisposed, !controller.isShuttingDown,
              let handle = controller.handle,
              let bindingID = controller.bindingID, let grant = controller.currentGrant,
              let editor = controller.editor.captureSnapshot(), editor.bindingID == bindingID,
              editor.revision.documentID == handle.identity, !editor.hasMarkedText,
              let state = IOSCopyOriginState(controller.documents.state(for: handle.identity)),
              handle.location.workspaceID == grant.workspaceID,
              editor.revision.version == handle.session.version,
              Self.exact(editor.document.text, handle.session.text)
        else { throw IOSConflictCopyFailure.originChanged }
        switch state {
        case let .conflict(generation, _, _, _):
            guard controller.grantIsCurrent, generation == grant.accessGeneration,
                  generation == handle.location.accessGeneration, editor.accessGeneration == generation
            else { throw IOSConflictCopyFailure.originChanged }
        case .unavailable:
            // The retained editor may already carry the newer revocation
            // generation. Copying its source needs only the new destination.
            break
        }
        self.draftID = draftID
        self.handle = handle
        self.bindingID = bindingID
        revision = editor.revision
        source = handle.session.text
        isDirty = handle.session.isDirty
        editorGeneration = editor.accessGeneration
        self.grant = grant
        grantWasCurrent = controller.grantIsCurrent
        self.state = state
    }

    static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func sameLocation(_ lhs: IOSFileLocation, _ rhs: IOSFileLocation) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.accessGeneration == rhs.accessGeneration &&
            exact(lhs.relativePath, rhs.relativePath) && lhs.fileURL.isFileURL && rhs.fileURL.isFileURL &&
            exact(lhs.fileURL.path(percentEncoded: false), rhs.fileURL.path(percentEncoded: false)) &&
            lhs.resourceID == rhs.resourceID
    }
}

enum IOSConflictCopyFilename {
    static func suggested(for url: URL, issuance: UUID) -> String {
        let suffix = url.pathExtension.lowercased()
        let ext = ["md", "markdown", "mdx"].contains(suffix) ? suffix : "md"
        var stem = url.deletingPathExtension().lastPathComponent
        while stem.utf8.count > 120 {
            stem.removeLast()
        }
        if stem.isEmpty {
            stem = "Document"
        }
        return "\(stem) Copy \(issuance.uuidString.prefix(8)).\(ext)"
    }

    static func validate(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.hasPrefix("."), WorkspaceRelativePath(spelling: name) != nil,
              ["md", "markdown", "mdx"].contains((name as NSString).pathExtension.lowercased())
        else { throw IOSConflictCopyFailure.invalidFilename }
        return name
    }
}
