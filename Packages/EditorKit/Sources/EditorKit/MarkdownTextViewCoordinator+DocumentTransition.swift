import AppKit
import STTextView
import SwiftUI

@MainActor
struct EditorDocumentTransitionCandidate {
    let generation: UInt64
    let sourceText: String
    let sourceSnapshot: EditorDocumentSourceSnapshot?
    let requestedSelection: NSRange?
    let navigationCommand: EditorNavigationCommand?
    let text: Binding<String>
    let selection: Binding<NSRange?>
    let documentIdentity: EditorDocumentIdentity?
    let documentBinding: EditorDocumentBindingRegistration?

    func recordFullSourceComparison(_ kind: EditorDocumentSourceFullComparisonKind) {
        documentBinding?.sourceContract?.recordFullSourceComparison(kind)
    }

    func refreshingSourceSnapshotForRetry() -> EditorDocumentTransitionCandidate {
        let currentSnapshot = documentBinding?.sourceContract?.snapshot()
        let refreshedSource = currentSnapshot?.source ?? text.wrappedValue
        let refreshedSelection: NSRange? = if case .navigate? = navigationCommand {
            // A distinct monotonic navigation request owns its exact range. Do not let
            // an unrelated Binding update replace that request while input is pending.
            requestedSelection
        } else {
            selection.wrappedValue
        }
        return EditorDocumentTransitionCandidate(
            generation: generation,
            sourceText: refreshedSource,
            sourceSnapshot: currentSnapshot,
            requestedSelection: refreshedSelection,
            navigationCommand: navigationCommand,
            text: text,
            selection: selection,
            documentIdentity: documentIdentity,
            documentBinding: documentBinding
        )
    }
}

struct EditorDocumentInstallation: Equatable {
    let generation: UInt64
}

@MainActor
struct EditorDocumentBindingRegistration {
    let id: EditorDocumentBindingID
    let lifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
    let sourceContract: EditorDocumentSourceContract?
}

@MainActor
struct EditorDocumentBindingTransition {
    let revoked: EditorDocumentBindingRegistration?
    let installed: EditorDocumentBindingRegistration?

    func notify(installationID: EditorDocumentBindingInstallationID) {
        if let installed {
            installed.lifecycle(.installed(EditorDocumentBindingInstallation(
                bindingID: installed.id,
                installationID: installationID
            )))
        }
        if let revoked {
            if let sourceContract = revoked.sourceContract {
                _ = sourceContract.writer(.release(EditorDocumentBindingInstallation(
                    bindingID: revoked.id,
                    installationID: installationID
                )))
            }
            revoked.lifecycle(.revoked(EditorDocumentBindingInstallation(
                bindingID: revoked.id,
                installationID: installationID
            )))
        }
    }

    func updateSourceSynchronizers(
        installationID: EditorDocumentBindingInstallationID,
        synchronizer: @escaping EditorDocumentSourceSynchronizer
    ) {
        if let revoked, let sourceContract = revoked.sourceContract {
            sourceContract.unregisterSourceSynchronizer(EditorDocumentBindingInstallation(
                bindingID: revoked.id,
                installationID: installationID
            ))
        }
        if let installed, let sourceContract = installed.sourceContract {
            sourceContract.registerSourceSynchronizer(
                EditorDocumentBindingInstallation(
                    bindingID: installed.id,
                    installationID: installationID
                ),
                synchronizer
            )
        }
    }
}
