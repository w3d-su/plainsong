import Foundation
import WorkspaceKitIOS

enum IOSConflictCopyFeedback {
    static func failure(_ error: Error) -> IOSConflictCopyFailure {
        if let failure = error as? IOSConflictCopyFailure {
            return failure
        }
        if error is CancellationError {
            return .cancelled
        }
        if let failure = error as? IOSDocumentFailure {
            if failure == .sourceChanged {
                return .sourceChanged
            }
            if case let .access(access) = failure {
                return self.failure(access)
            }
        }
        if let failure = error as? IOSWorkspaceFailure {
            if failure == .alreadyExists {
                return .alreadyExists
            }
            if failure == .grantChanged || failure == .permissionDenied {
                return .destinationChanged
            }
        }
        return .unavailable
    }

    static func notice(for outcome: IOSConflictCopyOutcome) -> IOSConflictCopyNotice? {
        switch outcome {
        case let .saved(filename):
            IOSConflictCopyNotice(
                title: "Copy Saved",
                message: "Saved \(filename). The original document still has a conflict. " +
                    "Your text and any existing recovery draft are retained."
            )
        case .cancelled: nil
        case let .refused(reason, mayExist):
            IOSConflictCopyNotice(
                title: "Copy Not Confirmed",
                message: message(for: reason) +
                    (mayExist ? " A copy may contain the earlier text; inspect the selected folder." : "") +
                    " Your current text and the original conflict are retained."
            )
        }
    }

    private static func message(for reason: IOSConflictCopyFailure) -> String {
        switch reason {
        case .invalidFilename: "Use a single Markdown or MDX filename without folders."
        case .alreadyExists:
            "A file with that name already exists. Choose another name; no existing file was replaced."
        case .sourceChanged: "The document changed while saving the copy."
        case .originChanged: "The document or its access changed. Start Save a Copy again."
        case .destinationChanged: "Access to the selected folder changed. Select the folder again."
        case .cancelled: "Saving the copy was cancelled."
        case .unavailable: "The copy could not be confirmed."
        }
    }
}
