import Combine
import Foundation
import WorkspaceKitIOS

/// Owns only modal issuance. Files authority and writer admission stay in the
/// existing scene; a new picker waits for the actual recent sheet dismissal.
@MainActor
final class IOSRecentPresentationController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var presenter: IOSRecentAccessPresenter?
    private(set) var isActive = false
    private(set) var presentationID: UUID?
    private var hasAppeared = false

    private enum Completion {
        case picker(IOSWorkspaceScope)
        case document
        case files
    }

    private weak var runtime: IOSProductionRuntime?
    private var pendingCompletion: Completion?
    private var reselectionScope: () -> IOSWorkspaceScope = { .singleFile }

    func bind(to runtime: IOSProductionRuntime) {
        self.runtime = runtime
    }

    func install(
        access: any IOSRecentWorkspaceAccess,
        openRecent: @escaping @MainActor (UUID) async throws -> Void,
        reselectionScope: @escaping () -> IOSWorkspaceScope
    ) {
        guard presenter == nil, let runtime else { return }
        self.reselectionScope = reselectionScope
        presenter = IOSRecentAccessPresenter(
            access: access, openRecent: openRecent,
            chooseAgain: { [weak self] scope in self?.chooseAgain(scope: scope) },
            didOpen: { [weak self] scope in self?.opened(scope: scope) }
        )
        runtime.scene.surfaces.showRecentWorkspaces = { [weak self] in self?.present() }
        runtime.scene.surfaces.reselectUnavailableWorkspace = { [weak self] in
            guard let self else { return }
            self.runtime?.requestPicker(scope: self.reselectionScope())
        }
    }

    func present() {
        guard !isActive, let runtime, runtime.canPresentRecentItems,
              let presenter, !presenter.isBusy else { return }
        runtime.prepareForReadOnlyPresentation()
        presenter.reload()
        pendingCompletion = nil
        isActive = true
        presentationID = UUID()
        hasAppeared = false
        isPresented = true
    }

    /// Called by explicit open routes before they create a picker issuance.
    /// A suspended recent operation stays busy until its provider drains.
    func redirectPickerUntilDismissed(scope: IOSWorkspaceScope) -> Bool {
        presenter?.cancelPendingOpen()
        guard isActive else { return false }
        guard hasAppeared else {
            retireUnpresentedRequest()
            return false
        }
        pendingCompletion = .picker(scope)
        isPresented = false
        return true
    }

    /// A late appearance from a retired sheet cannot adopt the next issuance.
    @discardableResult
    func didAppear(_ id: UUID) -> Bool {
        guard isActive, isPresented, presentationID == id else { return false }
        hasAppeared = true
        return true
    }

    /// The root calls this only from actual onDismiss. Consume the matching
    /// issuance once; a stale callback cannot issue another picker or navigation.
    func didDismiss(_ id: UUID?) {
        guard let id, isActive, presentationID == id else { return }
        isActive = false
        presentationID = nil
        hasAppeared = false
        presenter?.cancelPendingOpen()
        let completion = pendingCompletion
        pendingCompletion = nil
        guard let runtime else { return }
        switch completion {
        case let .picker(scope): runtime.requestPicker(scope: scope)
        case .document: runtime.scene.navigateToDocument()
        case .files: runtime.scene.navigationPath = []
        case nil: break
        }
    }

    /// OS-open and disposal supersede pending picker/navigation handoffs.
    func cancel() {
        presenter?.cancelPendingOpen()
        pendingCompletion = nil
        isPresented = false
        if !hasAppeared {
            retireUnpresentedRequest()
        }
    }

    private func retireUnpresentedRequest() {
        pendingCompletion = nil
        isPresented = false
        presentationID = nil
        isActive = false
    }

    private func chooseAgain(scope: IOSWorkspaceScope) {
        guard isActive, isPresented else { return }
        _ = redirectPickerUntilDismissed(scope: scope)
    }

    private func opened(scope: IOSWorkspaceScope) {
        guard isActive, isPresented else { return }
        pendingCompletion = scope == .singleFile ? .document : .files
        isPresented = false
    }
}
