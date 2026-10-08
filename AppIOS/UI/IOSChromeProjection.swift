import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

/// Navigation destinations for the compact-width stack.
enum IOSShellRoute: Hashable {
    case document
}

/// User-facing error surfaced by the shell's `.alert`.
struct IOSShellError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Deduplicated, Equatable projection of everything shell chrome needs.
/// Facade/document/editor observations publish at keystroke frequency; chrome
/// only republishes when one of these facts actually changes (the same
/// MenuBarState discipline the macOS shell uses for NSMenu churn).
struct IOSShellChromeSnapshot: Equatable {
    enum Status: Equatable {
        case noDocument
        case opening
        case ready
        case conflict
        case unavailable
        case closed
    }

    var documentIdentity: IOSDocumentIdentity?
    var documentTitle = "Untitled"
    var documentKind: FileKind?
    var isDirty = false
    var isSaving = false
    var status: Status = .noDocument
    var statusDetail: String?
    var hasWorkspace = false
    var editorCanWrite = false
    var editorFocused = false
    var editorHasMarkedText = false
    var sceneUnavailableReason: String?

    init(scene: IOSAppSceneSnapshot, editor: IOSSourceEditorSnapshot?) {
        sceneUnavailableReason = scene.unavailableReason
        hasWorkspace = scene.workspace != nil
        editorFocused = editor?.isFocused ?? false
        editorHasMarkedText = editor?.hasMarkedText ?? false

        guard let stored = scene.document else {
            editorCanWrite = false
            status = .noDocument
            return
        }
        documentIdentity = stored.revision.documentID
        documentKind = stored.document.fileKind
        isDirty = stored.document.isDirty
        // Writability is the AND of the document store's state (read-only ACL,
        // conflict, unavailable) and the editor binding's own flag. A
        // conflicted store always wins even if a stale snapshot disagrees.
        editorCanWrite = stored.state.canWrite && (editor?.canWrite ?? true)
        if let name = stored.location.relativePath.split(separator: "/").last {
            documentTitle = String(name)
        } else {
            documentTitle = stored.document.fileURL?.lastPathComponent ?? "Untitled"
        }

        switch stored.state {
        case .opening:
            status = .opening
        case .ready:
            status = .ready
        case .saving:
            status = .ready
            isSaving = true
        case let .conflict(_, recovery):
            status = .conflict
            statusDetail = recovery == nil
                ? "The file changed outside this editor."
                : "The file changed outside this editor. A recovery copy of your edits was saved."
        case let .unavailable(_, reason):
            status = .unavailable
            statusDetail = IOSShellChromeSnapshot.describe(reason)
        case .closed:
            status = .closed
        }
    }

    var hasDocument: Bool {
        switch status {
        case .noDocument, .closed: false
        case .opening, .ready, .conflict, .unavailable: true
        }
    }

    var canSave: Bool {
        status == .ready && isDirty
    }

    private static func describe(_ failure: IOSDocumentFailure) -> String {
        switch failure {
        case .unavailable: "The document is unavailable."
        case let .access(failure): "Access failed: \(String(describing: failure))."
        case .documentChanged: "The document changed underneath the editor."
        case .sourceChanged: "The source changed underneath the editor."
        case .conflict: "The document has an unresolved conflict."
        case .saveFailed: "Saving failed."
        case .closeFailed: "Closing failed."
        case .recoveryFailed: "Writing a recovery copy failed."
        case .indeterminate: "The last operation's result is unknown."
        }
    }
}
