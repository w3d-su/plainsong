import Foundation
import WorkspaceKitIOS

/// User-facing descriptions shared by production operations and shell chrome.
/// Provider enums remain diagnostics, never alert copy.
enum IOSOperationFeedback {
    static func message(for error: Error) -> String {
        if let failure = error as? IOSWorkspaceFailure {
            return message(for: failure)
        }
        guard let failure = error as? IOSDocumentFailure else {
            return "The operation couldn't finish. Try again or choose another file or folder."
        }
        switch failure {
        case let .access(reason): return message(for: reason)
        case .unavailable: return "The document isn't available. Your current text is retained."
        case .documentChanged: return "The document or its access changed. Try the operation again."
        case .sourceChanged: return "The text changed during the operation. Your current text is retained."
        case .conflict: return "The file changed outside this editor. Save a copy of your text or review the disk version."
        case .saveFailed: return "The file couldn't be saved. Your current text is retained. Try again when its provider is available."
        case .closeFailed:
            return "The current document is still open. Its provider or an external file change prevented a safe close. " +
                "Try again when the provider is available."
        case .recoveryFailed: return "A recovery draft couldn't be saved. Keep this document open and save your text to a writable location."
        case .indeterminate: return "The last operation couldn't be confirmed. Check the selected location before trying again."
        }
    }

    private static func message(for failure: IOSWorkspaceFailure) -> String {
        switch failure {
        case .permissionDenied, .grantChanged, .outsideGrant:
            "Access is no longer available. Choose the file or folder again."
        case .offline, .downloading:
            "The file isn't available yet. Check its download and connection, then try again."
        case .unsupportedType: "Choose a Markdown or MDX document."
        case .notFound: "The file could not be found. Choose it again in Files."
        case .readOnly: "This location is read only. Choose a writable location."
        case .alreadyExists: "A file with that name already exists. Choose another name."
        case .requiresDirectoryGrant: "Choose a folder to allow this operation."
        case .invalidPath: "Choose a valid file or folder in Files."
        case .tooLarge: "This file is too large for this operation."
        case .unavailable, .coordinationFailed:
            "The file provider couldn't finish the operation. Your current text is retained. Try again."
        case .indeterminate:
            "The file operation couldn't be confirmed. Check the selected location before trying again."
        }
    }
}
