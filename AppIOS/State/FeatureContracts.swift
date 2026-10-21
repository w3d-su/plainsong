import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

/// 08 supplies descriptors and handlers; 10 installs keyboard actions once per scene.
enum IOSAuthoringActionID: Hashable, Sendable {
    case bold, italic, link, heading(Int), code
    case strikethrough, inlineCode, paragraph, quote, codeFence
    case inlineMath, displayMath, checkbox, formatTable
    case find, nextMatch, previousMatch, useSelectionForFind, singleReplace
}

struct IOSKeyboardModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let command = IOSKeyboardModifiers(rawValue: 1 << 0)
    static let shift = IOSKeyboardModifiers(rawValue: 1 << 1)
    static let option = IOSKeyboardModifiers(rawValue: 1 << 2)
    static let control = IOSKeyboardModifiers(rawValue: 1 << 3)
}

enum IOSAuthoringActionPlacement: Hashable, Sendable {
    case toolbar
    case toolbarGroup(String)
    case formatMenu
    case find
}

struct IOSAuthoringAction: Sendable {
    let id: IOSAuthoringActionID
    let title: String
    let accessibilityLabel: String
    let placement: IOSAuthoringActionPlacement
    let keyboardInput: String?
    let keyboardModifiers: IOSKeyboardModifiers
}

@MainActor
protocol IOSAuthoringActionProviding: AnyObject {
    var actions: [IOSAuthoringAction] { get }
    func isEnabled(_ action: IOSAuthoringActionID, snapshot: IOSSourceEditorSnapshot?) -> Bool
    func perform(_ action: IOSAuthoringActionID, using editor: any IOSSourceEditorControlling)
}

/// 09 captures this before showing a picker; insert cannot retarget the latest caret.
struct IOSImageInsertionContext: Sendable {
    let operationID: UUID
    let editor: IOSSourceEditorSnapshot
    let destination: IOSFileLocation
    let grant: IOSWorkspaceGrant
}

enum IOSImageInsertionOutcome: Sendable {
    /// Ownership retention after accepted source insertion is not a failed edit.
    case inserted(IOSDocumentRevision, ownership: IOSAssetCommitOutcome)
    case refused(IOSEditRefusal)
    case failed(IOSWorkspaceFailure)
    case retained(IOSAssetRecoveryReceipt)
    case cancelled
}

@MainActor
protocol IOSImageInsertionControlling: AnyObject {
    func captureContext(
        using editor: any IOSSourceEditorControlling,
        destination: IOSFileLocation,
        grant: IOSWorkspaceGrant
    ) -> IOSImageInsertionContext?
    /// Photos/Files normalization supplies bytes; 06 alone persists the asset.
    func insert(
        bytes: Data,
        contentType: String,
        preferredFilename: String,
        context: IOSImageInsertionContext,
        using editor: any IOSSourceEditorControlling
    ) async -> IOSImageInsertionOutcome
    func cancel(operationID: UUID)
}
