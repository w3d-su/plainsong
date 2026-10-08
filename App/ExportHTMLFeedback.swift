import Darwin
import Foundation
import WorkspaceKit

/// What the Export as HTML… status banner shows: progress with Cancel while the operation
/// renders and writes, then one result notice. Cancel and supersession are silent.
enum ExportHTMLStatus: Equatable {
    case exporting(operationID: UInt64, fileName: String)
    case notice(ExportHTMLNotice)
}

/// How serious a notice is. The banner shows it as an SF Symbol plus a spoken word, never by
/// color alone (`docs/export-gates.md` E7).
enum ExportHTMLNoticeSeverity: String, Equatable {
    case success
    case warning
    case failure

    var spokenPrefix: String {
        switch self {
        case .success: "Done"
        case .warning: "Warning"
        case .failure: "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }
}

/// The message groups of handoff 12's feedback table. Each has its own accessibility
/// identifier so hosted tests and UI automation can tell them apart.
enum ExportHTMLNoticeGroup: String, CaseIterable, Equatable {
    case exported
    case exportedWithPlaceholders
    case destinationAlias
    case destinationUnreadable
    case destinationChanged
    case ownedDestination
    case linkOrNonRegularDestination
    case unsupportedLocation
    case permissionMissing
    case coordinationFailed
    case invalidName
    case writeFailed
    case saveDocumentFirst
    case recoveryUnavailable
    case documentChanged
    case workspaceChanged
    case editorBusy
    case renderFailed
    case resourceFailed
    case mdxError
    case indeterminate
}

struct ExportHTMLNotice: Equatable {
    let operationID: UInt64
    let group: ExportHTMLNoticeGroup
    let severity: ExportHTMLNoticeSeverity
    let title: String
    let message: String
    /// The item Reveal in Finder selects, when there is one worth recovering or opening.
    let revealURL: URL?

    /// The banner's spoken label: severity word, title, and the full message with every path.
    var accessibilityLabel: String {
        "\(severity.spokenPrefix): \(title). \(message)"
    }

    var accessibilityIdentifier: String {
        ExportHTMLAccessibility.notice(group)
    }
}

/// Maps every operation result to its user-visible notice (`nil` for a silent result).
enum ExportHTMLNoticeMapper {
    static let failureTitle = "Could Not Export as HTML"
    static let nothingWritten = "Nothing was written."

    static func notice(
        for result: ExportHTMLOperationResult,
        operationID: UInt64
    ) -> ExportHTMLNotice? {
        switch result {
        case .stopped(.cancelled), .stopped(.superseded),
             .written(.notCommitted(.cancelled)), .stopped(.destinationRefused(.cancelled)):
            nil
        case let .stopped(reason):
            stopped(reason, operationID: operationID)
        case let .written(.notCommitted(failure)):
            notCommitted(failure, operationID: operationID)
        case let .written(.indeterminate(write)):
            indeterminate(write, operationID: operationID)
        case let .exported(commit, omittedImageCount):
            exported(commit, omittedImageCount: omittedImageCount, operationID: operationID)
        case let .written(.committed(commit)):
            exported(commit, omittedImageCount: 0, operationID: operationID)
        }
    }

    static func exported(
        _ commit: ExportArtifactCommit,
        omittedImageCount: Int,
        operationID: UInt64
    ) -> ExportHTMLNotice {
        let name = commit.selectedURL.lastPathComponent
        let folder = commit.selectedURL.deletingLastPathComponent().path(percentEncoded: false)
        var message = "“\(name)” was exported to \(folder)."
        guard omittedImageCount > 0 else {
            return ExportHTMLNotice(
                operationID: operationID,
                group: .exported,
                severity: .success,
                title: "Exported as HTML",
                message: message,
                revealURL: commit.selectedURL
            )
        }
        message += omittedImageCount == 1
            ? " 1 image couldn’t be embedded and was replaced by a placeholder with its description."
            : " \(omittedImageCount) images couldn’t be embedded and were replaced by placeholders " +
            "with their descriptions."
        message += " Only local PNG, JPEG, GIF, or WebP images up to 10 MB are embedded; " +
            "remote images are never downloaded."
        return ExportHTMLNotice(
            operationID: operationID,
            group: .exportedWithPlaceholders,
            severity: .warning,
            title: "Exported as HTML with Image Placeholders",
            message: message,
            revealURL: commit.selectedURL
        )
    }

    static func stopped(_ reason: ExportHTMLStopReason, operationID: UInt64) -> ExportHTMLNotice? {
        let (group, title, detail): (ExportHTMLNoticeGroup, String, String)
        switch reason {
        case .cancelled, .superseded, .destinationRefused(.cancelled):
            return nil
        case let .destinationRefused(failure):
            return notCommitted(failure, operationID: operationID)
        case .untitledDocument, .unprovenDocumentOwnership:
            (group, title, detail) = (
                .saveDocumentFirst,
                "Save the Document First",
                "Save the document first, then export it as HTML. Plainsong can’t check an export " +
                    "destination against an unsaved or recovered document."
            )
        case .recoveryStoresUnavailable:
            (group, title, detail) = (
                .recoveryUnavailable,
                failureTitle,
                "Plainsong couldn’t load its workspace recovery records, so it can’t confirm that a " +
                    "destination is safe to write."
            )
        case .documentChanged:
            (group, title, detail) = (
                .documentChanged,
                failureTitle,
                "The document was edited, switched, moved, or closed while it was being exported. " +
                    "Export again to include the latest version."
            )
        case .workspaceChanged:
            (group, title, detail) = (
                .workspaceChanged,
                failureTitle,
                "The workspace was closed or switched while the document was being exported."
            )
        case .pendingEditorSource:
            (group, title, detail) = (
                .editorBusy,
                failureTitle,
                "The editor was still applying your latest typing. Try again."
            )
        case .renderFailed(reason: "mdx-stale-or-error"):
            (group, title, detail) = (
                .mdxError,
                failureTitle,
                "The MDX document has a syntax error, so it can’t be exported. Fix the error shown in " +
                    "the preview, then export again."
            )
        case let .renderFailed(reason) where ["invalid-export-resources", "invalid-finalization",
                                              "resources-changed", "image-undecoded", "html-too-large"]
                 .contains(reason):
            (group, title, detail) = (
                .resourceFailed,
                failureTitle,
                reason == "html-too-large"
                    ? "The exported HTML exceeds the 64 MiB limit. Reduce the document’s images or content, then try again."
                    : "The document’s images or fonts couldn’t be prepared for export. Try again."
            )
        case .renderFailed(reason: "timeout"):
            (group, title, detail) = (.renderFailed, failureTitle, "The export took too long. Try again.")
        case .renderFailed:
            (group, title, detail) = (
                .renderFailed,
                failureTitle,
                "The document couldn’t be rendered for export. Try again."
            )
        }
        return ExportHTMLNotice(
            operationID: operationID,
            group: group,
            severity: .failure,
            title: title,
            message: "\(nothingWritten) \(detail)",
            revealURL: nil
        )
    }

    static func notCommitted(_ failure: ExportArtifactFailure, operationID: UInt64) -> ExportHTMLNotice? {
        guard let (group, detail) = notCommittedDetail(failure) else { return nil }
        return ExportHTMLNotice(
            operationID: operationID,
            group: group,
            severity: .failure,
            title: failureTitle,
            message: "\(nothingWritten) \(detail)",
            revealURL: nil
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func notCommittedDetail(
        _ failure: ExportArtifactFailure
    ) -> (ExportHTMLNoticeGroup, String)? {
        switch failure {
        case .cancelled:
            nil
        case .destinationAlias:
            (.destinationAlias, "A file or folder there has the same name with different capitalization or " +
                "accents, the folder path is spelled differently on disk, or the file has another " +
                "hard-link name. Choose the existing name, or a different name.")
        case let .destinationUnreadable(code):
            (.destinationUnreadable, "The existing file can’t be read (\(posixDescription(code))), so it " +
                "can’t be replaced safely. Choose a different name.")
        case .destinationAlreadyExists, .destinationIdentityChanged, .destinationMissing, .namespaceChanged:
            (.destinationChanged, "The destination changed while the document was being exported. Try again.")
        case .ownedDestination:
            (.ownedDestination, "That file is open in Plainsong or reserved by it (a document, a recovery " +
                "copy, or a quarantined file). Choose another name.")
        case .symbolicLinkDestination, .symbolicLinkInParentPath, .nonRegularDestination:
            (.linkOrNonRegularDestination, "The destination, or a folder on its path, is a link or not a " +
                "regular file. Choose a different name or location.")
        case .unsupportedVolumeSemantics, .stagingDirectoryOnDifferentDevice, .stagingDirectoryUnavailable,
             .stagingDirectoryInsideDestinationFolder:
            (.unsupportedLocation, "Plainsong can’t export safely to this location or volume. Choose a " +
                "folder on your Mac or in iCloud Drive.")
        case .stagingNotPermitted, .publicationNotPermitted, .parentAuthorityUnavailable:
            (.permissionMissing, "Plainsong wasn’t given permission to write there. Choose the location " +
                "again in the Export panel.")
        case .coordinationFailed:
            (.coordinationFailed, "iCloud Drive didn’t allow the file to be written right now. Try again " +
                "in a moment.")
        case .invalidDestinationURL, .unsupportedExtension:
            (.invalidName, "That name or location can’t be used for an HTML file. Choose a name ending " +
                "in .html.")
        case let .stagingUnavailable(code):
            (.writeFailed, "Writing failed (\(posixDescription(code))). Nothing was published.")
        case let .writeFailed(error):
            (.writeFailed, "Writing failed (\(writeErrorDescription(error))). Nothing was published.")
        }
    }

    static func indeterminate(
        _ write: ExportArtifactIndeterminateWrite,
        operationID: UInt64
    ) -> ExportHTMLNotice {
        var lines = ["Plainsong couldn’t confirm the export to \(path(write.selectedURL))."]
        switch write.destinationState {
        case .holdsWriterBytes:
            lines.append("That file now holds the exported HTML, but cleanup couldn’t be confirmed.")
        case .provenUnchanged:
            lines.append("That file was not changed.")
        case .unknown:
            lines.append("Plainsong can’t tell what that file now contains; check it before relying on it.")
        }
        var revealURL: URL?
        switch write.residue {
        case .none:
            break
        case let .retained(url, .displacedOriginal):
            var line = "Your original file is now at \(path(url))."
            if write.residueIsInPurgeableTemporaryFolder {
                line += " This is a hidden temporary folder that macOS may clear, so recover the file now."
            }
            lines.append(line)
            revealURL = url
        case let .retained(url, .writerBytes):
            lines.append("A copy of the exported HTML remains at \(path(url)).")
            revealURL = url
        case let .retained(url, .unknown):
            lines.append("An unexpected item remains at \(path(url)). It may be your data; inspect it " +
                "before deleting anything.")
            revealURL = url
        case let .removalIndeterminate(url):
            lines.append("Plainsong couldn’t confirm whether \(path(url)) was removed. It may be your data; " +
                "inspect it before deleting anything.")
            revealURL = url
        }
        if let stagingURL = write.stagingURL, stagingURL != write.residue.url {
            lines.append("Temporary file to inspect: \(path(stagingURL)).")
        }
        if let directoryURL = write.itemReplacementDirectoryURL {
            lines.append("Temporary folder not proven removed: \(path(directoryURL)).")
            revealURL = revealURL ?? directoryURL
        }
        if !write.unprovenDirectoryURLs.isEmpty {
            let paths = write.unprovenDirectoryURLs.map(path).joined(separator: ", ")
            lines
                .append(
                    "Folders not proven removed: \(paths). They may already have existed and may be shared — do not delete them."
                )
        }
        return ExportHTMLNotice(
            operationID: operationID,
            group: .indeterminate,
            severity: .failure,
            title: "HTML Export Could Not Be Confirmed",
            message: lines.joined(separator: " "),
            revealURL: revealURL ?? write.selectedURL
        )
    }

    static func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    static func posixDescription(_ code: Int32) -> String {
        "\(String(cString: strerror(code))), error \(code)"
    }

    static func writeErrorDescription(_ error: WorkspaceAnchoredFileSystemError) -> String {
        switch error {
        case .missing: "a file it needed was missing"
        case .symbolicLink: "a symbolic link was found on the path"
        case .notRegularFile: "an item on the path was not a regular file"
        case .unreadable: "an item could not be read"
        case .changedIdentity, .changedContent, .namespaceChanged, .unstable:
            "the destination changed during the write"
        case .durabilityFailed: "the data could not be flushed to disk"
        case .cleanupFailed: "temporary files could not be cleaned up"
        case .cancelled: "the write was cancelled"
        }
    }
}
