import Combine
import Foundation
import WorkspaceKitIOS

@MainActor
struct IOSRecoveryPickerRequest: Identifiable {
    let id = UUID()
    let capture: IOSRecoveryRestoreCapture
    let presentationID: UUID
}

/// UI holds immutable readback only. All document writes remain in composition.
@MainActor
final class IOSRecoveryController: ObservableObject {
    typealias Restore = @MainActor (
        IOSRecoveryRestoreCapture, URL, @escaping @MainActor () -> Bool
    ) async throws -> Void

    @Published var isPresented = false
    @Published private(set) var records: [IOSRecoveryRecord] = []
    @Published private(set) var corruptCount = 0
    @Published private(set) var detail: IOSRecoveryRecord?
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoring = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pickerRequest: IOSRecoveryPickerRequest?
    var onRestored: (() -> Void)?
    var onPresent: (() -> Void)?

    private let list: @MainActor () async -> IOSRecoveryList
    private let load: @MainActor (UUID) async throws -> IOSRecoveryRecord
    private let capture: @MainActor (IOSRecoveryRecord) throws -> IOSRecoveryRestoreCapture
    private let restore: Restore
    private var readID = UUID()
    private var activeRestoreID: UUID?
    private(set) var presentationID: UUID?
    private var hasAppeared = false
    private var restoredPresentationID: UUID?

    init(
        list: @escaping @MainActor () async -> IOSRecoveryList,
        load: @escaping @MainActor (UUID) async throws -> IOSRecoveryRecord,
        capture: @escaping @MainActor (IOSRecoveryRecord) throws -> IOSRecoveryRestoreCapture,
        restore: @escaping Restore
    ) {
        self.list = list
        self.load = load
        self.capture = capture
        self.restore = restore
    }

    func present() {
        guard presentationID == nil, !isRestoring else { return }
        onPresent?()
        presentationID = UUID()
        hasAppeared = false
        restoredPresentationID = nil
        isPresented = true
    }

    @discardableResult
    func didAppear(_ id: UUID) -> Bool {
        guard isPresented, presentationID == id else { return false }
        hasAppeared = true
        return true
    }

    /// Consume navigation only from the matching sheet's actual dismissal.
    func didDismiss(_ id: UUID?) {
        guard let id, presentationID == id, hasAppeared else { return }
        let restored = restoredPresentationID == id
        presentationID = nil
        hasAppeared = false
        restoredPresentationID = nil
        readID = UUID()
        isLoading = false
        cancelPicker()
        if restored {
            onRestored?()
        }
    }

    func refresh() async {
        guard !isRestoring else { return }
        cancelPicker()
        let request = UUID()
        readID = request
        detail = nil
        errorMessage = nil
        isLoading = true
        let result = await list()
        guard readID == request else { return }
        records = result.records.sorted {
            let first = Self.filename($0), second = Self.filename($1)
            if !first.utf8.elementsEqual(second.utf8) {
                return first.utf8.lexicographicallyPrecedes(second.utf8)
            }
            if $0.revisionVersion != $1.revisionVersion {
                return $0.revisionVersion > $1.revisionVersion
            }
            return $0.recordID.uuidString < $1.recordID.uuidString
        }
        corruptCount = result.corruptNames.count
        isLoading = false
    }

    func select(_ recordID: UUID) async {
        guard !isRestoring else { return }
        cancelPicker()
        let request = UUID()
        readID = request
        detail = nil
        errorMessage = nil
        isLoading = true
        do {
            let record = try await load(recordID)
            guard readID == request else { return }
            guard record.recordID == recordID else { throw IOSRecoveryDiscardError.corrupt }
            detail = record
        } catch {
            guard readID == request else { return }
            errorMessage = "This recovery draft could not be read. Other drafts and your open document are retained."
        }
        isLoading = false
    }

    func backToList() {
        guard !isRestoring else { return }
        readID = UUID()
        isLoading = false
        detail = nil
        errorMessage = nil
        cancelPicker()
    }

    func requestRestore() {
        guard isPresented, let presentationID, !isRestoring, pickerRequest == nil, let detail else { return }
        do {
            let request = try IOSRecoveryPickerRequest(capture: capture(detail), presentationID: presentationID)
            activeRestoreID = request.id
            pickerRequest = request
            errorMessage = nil
        } catch {
            errorMessage = "Finish the current edit or document operation, then try restoring again."
        }
    }

    func cancelPicker() {
        activeRestoreID = nil
        pickerRequest = nil
    }

    /// External navigation/disposal cancels a pending completion. A visible
    /// sheet keeps its issuance until UIKit reports actual dismissal.
    func dismiss() {
        readID = UUID()
        isLoading = false
        cancelPicker()
        restoredPresentationID = nil
        isPresented = false
        if !hasAppeared {
            presentationID = nil
        }
    }

    @discardableResult
    func completePicker(_ request: IOSRecoveryPickerRequest, urls: [URL]) -> Task<Void, Never>? {
        guard pickerRequest?.id == request.id, activeRestoreID == request.id,
              presentationID == request.presentationID else { return nil }
        pickerRequest = nil
        guard urls.count == 1, let folder = urls.first else {
            activeRestoreID = nil
            return nil
        }
        isRestoring = true
        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isRestoring = false
                if activeRestoreID == request.id {
                    activeRestoreID = nil
                }
            }
            do {
                try await restore(request.capture, folder) { [weak self] in
                    self?.activeRestoreID == request.id && self?.presentationID == request.presentationID
                }
                guard activeRestoreID == request.id, presentationID == request.presentationID else { return }
                restoredPresentationID = request.presentationID
                isPresented = false
            } catch {
                guard activeRestoreID == request.id, presentationID == request.presentationID else { return }
                errorMessage = Self.message(for: error)
            }
        }
    }

    private static func filename(_ record: IOSRecoveryRecord) -> String {
        let path = String(data: record.relativePathUTF8, encoding: .utf8) ?? ""
        return (path as NSString).lastPathComponent
    }

    private static func message(for error: Error) -> String {
        if error is IOSRecoveryCreatedFileRefreshFailure {
            return "The restored file was created and is retained. Only the Files list could not refresh. " +
                "Close Recovered Drafts and use Refresh in Files; select its folder again if access changed. " +
                "No new restore is needed. Your original file and recovery draft are retained."
        }
        if let failure = error as? IOSRecoveryRestoreFailure {
            let previous = failure.previousDocumentClosed
                ? "Your previous document was safely closed and its folder is no longer open."
                : "Your previous folder is no longer open."
            return "The restore could not finish. \(previous) " +
                "This restore did not overwrite the previous file or remove the recovery draft. " +
                "Close Recovered Drafts and use Open to reopen the previous file or folder, " +
                "or try restoring into another folder."
        }
        if let failure = error as? IOSDocumentFailure {
            switch failure {
            case .access(.alreadyExists):
                return "A restored file with this name already exists. Choose another folder; nothing was overwritten."
            case .closeFailed, .conflict:
                return "Resolve the open document before restoring. Its edits and this recovery draft are retained."
            case .sourceChanged, .documentChanged:
                return "The open document or recovery draft changed. Review it and start Restore as New File again."
            default: break
            }
        }
        return "The restore could not finish. Your recovery draft is retained. Check folder access and try again."
    }
}
