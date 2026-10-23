import Combine
import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

struct IOSImagePickedPayload: Sendable, Equatable {
    let bytes: Data
    let contentType: String
    let preferredFilename: String
}

enum IOSImagePickFailure: Error, Equatable, Sendable {
    case unsupportedType
    case tooLarge
    case unavailable

    var workspaceFailure: IOSWorkspaceFailure {
        switch self {
        case .unsupportedType: .unsupportedType
        case .tooLarge: .tooLarge
        case .unavailable: .unavailable
        }
    }
}

enum IOSImageInsertionPhase: Equatable {
    case idle
    case needsDirectoryGrant
    case picking(UUID)
    case importing(UUID)
    case inserted(IOSDocumentRevision, ownershipRetained: Bool)
    case refused(IOSEditRefusal)
    case failed(IOSWorkspaceFailure)
    case retained(relativePath: String)
    case cancelled
}

enum IOSImageInsertionMessages {
    static func needsDirectoryGrant() -> String {
        "Choose a folder before inserting an image. Nothing was saved and the document was not changed."
    }

    static func recovery(relativePath: String) -> String {
        "The image was saved but not inserted. Relative path: \(relativePath). The file was not deleted."
    }
}

/// Picker-facing flow. It captures once, then either inserts or discards that same operation.
@MainActor
final class IOSImageInsertionSession: ObservableObject {
    @Published private(set) var phase: IOSImageInsertionPhase = .idle

    private let controller: IOSImageInsertionController
    private let editor: any IOSSourceEditorControlling
    private let destination: IOSFileLocation
    private let grant: IOSWorkspaceGrant
    private let onRequestDirectoryGrant: () -> Void
    private var inFlight: IOSImageInsertionContext?
    private var importing = false
    private var finishing = false

    init(
        controller: IOSImageInsertionController,
        editor: any IOSSourceEditorControlling,
        destination: IOSFileLocation,
        grant: IOSWorkspaceGrant,
        onRequestDirectoryGrant: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.editor = editor
        self.destination = destination
        self.grant = grant
        self.onRequestDirectoryGrant = onRequestDirectoryGrant
    }

    func preparePicker() -> IOSImageInsertionContext? {
        guard !importing, inFlight == nil else { return nil }
        guard let snapshot = editor.captureSnapshot() else {
            phase = .failed(.unavailable)
            return nil
        }
        if let block = IOSImageInsertionGuard.captureBlock(snapshot: snapshot, destination: destination, grant: grant) {
            phase = Self.phase(for: block)
            return nil
        }
        guard let context = controller.captureContext(using: editor, destination: destination, grant: grant) else {
            phase = .failed(.unavailable)
            return nil
        }
        inFlight = context
        phase = .picking(context.operationID)
        return context
    }

    func requestDirectoryGrant() {
        phase = .needsDirectoryGrant
        onRequestDirectoryGrant()
    }

    func beginImport() -> IOSImageInsertionContext? {
        guard !importing, let inFlight, case .picking = phase else { return nil }
        importing = true
        phase = .importing(inFlight.operationID)
        return inFlight
    }

    func pickerDismissed() {
        abandonPicking()
    }

    func teardown() {
        guard let inFlight else { return }
        controller.cancel(operationID: inFlight.operationID)
        abandonPicking()
    }

    func finishImport(
        _ result: Result<IOSImagePickedPayload, IOSImagePickFailure>,
        context: IOSImageInsertionContext
    ) async {
        guard !finishing, importing, inFlight?.operationID == context.operationID else { return }
        finishing = true
        defer {
            finishing = false
            importing = false
            if inFlight?.operationID == context.operationID {
                inFlight = nil
            }
        }
        let outcome: IOSImageInsertionOutcome
        switch result {
        case let .failure(failure):
            controller.discardUnstaged(operationID: context.operationID)
            outcome = .failed(failure.workspaceFailure)
        case let .success(payload):
            outcome = await controller.insert(
                bytes: payload.bytes,
                contentType: payload.contentType,
                preferredFilename: payload.preferredFilename,
                context: context,
                using: editor
            )
        }
        phase = Self.phase(for: outcome)
    }

    private func abandonPicking() {
        guard let inFlight, case .picking = phase else { return }
        controller.discardUnstaged(operationID: inFlight.operationID)
        self.inFlight = nil
        phase = .cancelled
    }

    private static func phase(for block: IOSImageCaptureBlock) -> IOSImageInsertionPhase {
        switch block {
        case .needsDirectoryGrant:
            .needsDirectoryGrant
        case let .editorUnavailable(refusal):
            .refused(refusal)
        case let .destinationInvalid(failure):
            .failed(failure)
        }
    }

    private static func phase(for outcome: IOSImageInsertionOutcome) -> IOSImageInsertionPhase {
        switch outcome {
        case let .inserted(revision, ownership):
            .inserted(revision, ownershipRetained: Self.ownershipRetained(ownership))
        case let .refused(reason):
            .refused(reason)
        case let .failed(reason):
            .failed(reason)
        case let .retained(receipt):
            .retained(relativePath: receipt.targetLocation.relativePath)
        case .cancelled:
            .cancelled
        }
    }

    private static func ownershipRetained(_ ownership: IOSAssetCommitOutcome) -> Bool {
        if case .retained = ownership {
            return true
        }
        return false
    }
}
