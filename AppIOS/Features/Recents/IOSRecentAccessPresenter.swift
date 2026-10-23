import Combine
import Foundation
import WorkspaceKitIOS

struct IOSRecentAccessRow: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let scope: IOSWorkspaceScope
    let status: IOSRecentWorkspaceStatus

    var detail: String {
        let kind = scope == .directory ? "Folder" : "File"
        let availability = status == .available ? "Available" : "Choose Again Required"
        return "\(kind) · \(availability)"
    }
}

/// Owns UI issuance only. Opening still belongs to the scene's admitted writer.
@MainActor
final class IOSRecentAccessPresenter: ObservableObject {
    @Published private(set) var rows: [IOSRecentAccessRow] = []
    @Published private(set) var openingRecordID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let access: any IOSRecentWorkspaceAccess
    private let openRecent: @MainActor (UUID) async throws -> Void
    private let chooseAgain: @MainActor (IOSWorkspaceScope) -> Void
    private let didOpen: @MainActor (IOSWorkspaceScope) -> Void
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var epoch: UInt64 = 0

    init(
        access: any IOSRecentWorkspaceAccess,
        openRecent: @escaping @MainActor (UUID) async throws -> Void,
        chooseAgain: @escaping @MainActor (IOSWorkspaceScope) -> Void,
        didOpen: @escaping @MainActor (IOSWorkspaceScope) -> Void
    ) {
        self.access = access
        self.openRecent = openRecent
        self.chooseAgain = chooseAgain
        self.didOpen = didOpen
        reload()
    }

    func reload() {
        rows = access.recentItems().map {
            IOSRecentAccessRow(id: $0.recordID, displayName: $0.displayName, scope: $0.scope, status: $0.status)
        }
        if let openingRecordID, !rows.contains(where: { $0.id == openingRecordID }) {
            cancelPendingOpen()
        }
    }

    func open(recordID: UUID) {
        guard !isBusy, let row = rows.first(where: { $0.id == recordID }), row.status == .available else { return }
        let token = UUID()
        let capturedEpoch = epoch
        operationID = token
        openingRecordID = recordID
        isBusy = true
        errorMessage = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                try Task.checkCancellation()
                try await openRecent(recordID)
                succeeded = !Task.isCancelled && epoch == capturedEpoch && operationID == token
            } catch is CancellationError {
                // A cancelled issuance never routes a later completion to the UI.
            } catch {
                if !Task.isCancelled, epoch == capturedEpoch, operationID == token {
                    errorMessage = "The recent item could not be opened. Choose the file or folder again."
                }
            }
            guard operationID == token else { return }
            operation = nil
            operationID = nil
            openingRecordID = nil
            isBusy = false
            reload()
            if succeeded, epoch == capturedEpoch, rows.contains(where: { $0.id == recordID }) {
                didOpen(row.scope)
            }
        }
    }

    func chooseAgain(recordID: UUID) {
        guard !isBusy, let row = rows.first(where: { $0.id == recordID }) else { return }
        epoch &+= 1
        errorMessage = nil
        chooseAgain(row.scope)
    }

    func removeRecord(recordID: UUID) {
        guard rows.contains(where: { $0.id == recordID }) else { return }
        if openingRecordID == recordID {
            cancelPendingOpen()
        }
        access.removeRecent(recordID: recordID)
        reload()
    }

    /// Root calls this before another picker/OS-open issuance or scene disposal.
    /// Keep busy until the old operation drains; never start a second writer.
    func cancelPendingOpen() {
        epoch &+= 1
        operation?.cancel()
        openingRecordID = nil
    }
}
