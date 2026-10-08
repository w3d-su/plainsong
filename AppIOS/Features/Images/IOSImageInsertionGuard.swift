import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

enum IOSImageCaptureBlock: Equatable {
    case needsDirectoryGrant
    case editorUnavailable(IOSEditRefusal)
    case destinationInvalid(IOSWorkspaceFailure)
}

enum IOSImageInsertionGuard {
    static let undoActionName = "Insert Image"

    static func captureBlock(
        snapshot: IOSSourceEditorSnapshot,
        destination: IOSFileLocation,
        grant: IOSWorkspaceGrant
    ) -> IOSImageCaptureBlock? {
        if grant.scope != .directory {
            return .needsDirectoryGrant
        }
        // Grant identity and generation are the authority. A shared URL prefix is not.
        if grant.workspaceID != destination.workspaceID || grant.accessGeneration != destination.accessGeneration {
            return .destinationInvalid(.grantChanged)
        }
        if snapshot.accessGeneration != grant.accessGeneration {
            return .destinationInvalid(.grantChanged)
        }
        if !isRelativeDocumentPath(destination.relativePath) {
            return .destinationInvalid(.invalidPath)
        }
        if let refusal = editorBlock(snapshot) {
            return .editorUnavailable(refusal)
        }
        return nil
    }

    static func editorBlock(_ snapshot: IOSSourceEditorSnapshot) -> IOSEditRefusal? {
        if !snapshot.isFocused {
            return .notFocused
        }
        if !snapshot.canWrite {
            return .readOnly
        }
        if snapshot.hasMarkedText {
            return .markedText
        }
        return nil
    }

    static func refusal(captured: IOSSourceEditorSnapshot, current: IOSSourceEditorSnapshot) -> IOSEditRefusal? {
        if current.bindingID != captured.bindingID {
            return .bindingChanged
        }
        if current.revision.documentID != captured.revision.documentID {
            return .documentChanged
        }
        if current.revision.version != captured.revision.version {
            return .sourceChanged
        }
        if current.selectionGeneration != captured.selectionGeneration {
            return .selectionChanged
        }
        if current.accessGeneration != captured.accessGeneration {
            return .accessChanged
        }
        return editorBlock(current)
    }

    static func destinationFailure(
        _ asset: IOSStagedImageAsset,
        context: IOSImageInsertionContext
    ) -> IOSWorkspaceFailure? {
        if asset.operationID != context.operationID {
            return .indeterminate
        }
        if asset.targetLocation.workspaceID != context.destination.workspaceID {
            return .grantChanged
        }
        if asset.accessGeneration != context.destination.accessGeneration {
            return .grantChanged
        }
        if asset.targetLocation.workspaceID != context.grant.workspaceID {
            return .grantChanged
        }
        if asset.accessGeneration != context.grant.accessGeneration {
            return .grantChanged
        }
        return nil
    }

    static func authorizedEdit(
        context: IOSImageInsertionContext,
        relativePath: String
    ) -> IOSAuthorizedEdit? {
        guard let result = editResult(context: context, relativePath: relativePath) else { return nil }
        return IOSAuthorizedEdit(
            bindingID: context.editor.bindingID,
            baseRevision: context.editor.revision,
            selectionGeneration: context.editor.selectionGeneration,
            accessGeneration: context.editor.accessGeneration,
            result: result,
            undoActionName: undoActionName
        )
    }

    static func isRelativeDocumentPath(_ path: String) -> Bool {
        insertionPath(path) != nil
    }

    private static func editResult(
        context: IOSImageInsertionContext,
        relativePath: String
    ) -> MarkdownEditResult? {
        guard let path = insertionPath(relativePath) else { return nil }
        let replacement = SmartPaste.imageInsertion(relativePath: path)
        guard !replacement.isEmpty, replacement != "![]()" else { return nil }
        let source = context.editor.document.text as NSString
        let range = context.editor.selection
        guard fits(range, length: source.length) else { return nil }
        let inserted = (replacement as NSString).length
        let (location, overflow) = range.location.addingReportingOverflow(inserted)
        guard !overflow else { return nil }
        return MarkdownEditResult(
            replacementRange: range,
            replacementString: replacement,
            newSelection: NSRange(location: location, length: 0)
        )
    }

    /// Markdown-parent-relative leaf path. URL prefix, absolute paths, and `..` are not authority.
    static func insertionPath(_ path: String) -> String? {
        if path.isEmpty || path.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return nil
        }
        if path.hasPrefix("/") || path.contains("\\") || path.contains("://") {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return nil
        }
        return path
    }

    private static func fits(_ range: NSRange, length: Int) -> Bool {
        guard range.location >= 0, range.length >= 0, length >= 0 else { return false }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow && end <= length
    }
}
