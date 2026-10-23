import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceKitIOS

enum IOSImageTerminalAction: Sendable {
    case commit
    case rollback
}

enum IOSImageAssetTerminal: Sendable {
    case committed(IOSAssetCommitOutcome)
    case rolledBack(IOSAssetRollbackOutcome)
}

struct IOSImageTerminalRequest: Sendable {
    var failure: IOSWorkspaceFailure?
    var refusal: IOSEditRefusal?
    var cancelled = false
    var applied: IOSDocumentRevision?
    var action: IOSImageTerminalAction = .rollback

    static func rollback(
        failure: IOSWorkspaceFailure? = nil,
        refusal: IOSEditRefusal? = nil,
        cancelled: Bool = false
    ) -> IOSImageTerminalRequest {
        IOSImageTerminalRequest(
            failure: failure,
            refusal: refusal,
            cancelled: cancelled,
            applied: nil,
            action: IOSImageTerminalAction.rollback
        )
    }
}

enum IOSImageTerminalMapping {
    static func outcome(
        terminal: IOSImageAssetTerminal,
        asset: IOSStagedImageAsset,
        request: IOSImageTerminalRequest
    ) -> IOSImageInsertionOutcome {
        switch terminal {
        case let .committed(ownership):
            guard let applied = request.applied else { return .failed(.indeterminate) }
            return .inserted(applied, ownership: ownership)
        case let .rolledBack(.removed):
            return removed(asset: asset, request: request)
        case let .rolledBack(.retained(receipt)):
            if let applied = request.applied {
                return .inserted(applied, ownership: .retained(receipt))
            }
            return .retained(receipt)
        }
    }

    /// An owned leaf was removed and the source does not reference it.
    private static func removed(
        asset: IOSStagedImageAsset,
        request: IOSImageTerminalRequest
    ) -> IOSImageInsertionOutcome {
        if let applied = request.applied {
            let receipt = IOSAssetRecoveryReceipt(
                operationID: asset.operationID,
                targetLocation: asset.targetLocation,
                ownershipToken: asset.ownershipToken,
                reason: .indeterminate
            )
            return .inserted(applied, ownership: .retained(receipt))
        }
        if let refusal = request.refusal {
            return .refused(refusal)
        }
        if let failure = request.failure {
            return .failed(failure)
        }
        if request.cancelled {
            return .cancelled
        }
        return .failed(.indeterminate)
    }
}

final class IOSImageOperationState {
    enum Phase {
        case captured
        case importing
        case finished
    }

    var phase: Phase = .captured
    var cancelRequested = false
    var staged: IOSStagedImageAsset?
    var terminalTask: Task<IOSImageAssetTerminal, Never>?
    var earlyOutcome: IOSImageInsertionOutcome?
}
