import AppKit
import Combine
import SwiftUI

/// Tracks the `NSWindow` that currently hosts a SwiftUI hierarchy, live key state, and the
/// concrete Search query `NSTextField` for this window.
///
/// Environment `controlActiveState` is frozen on the `View` value across `await`, so delayed
/// focus work must re-read key status from the host window (or an AppState test override) after
/// every suspension. Field-mount epochs cover the first `⌘⇧F` path where `.files → .search`
/// and the focus token race the TextField install.
@MainActor
final class WindowKeyStateTracker: ObservableObject {
    /// Bumped when the host window binds or becomes/resigns key.
    @Published private(set) var keyEpoch: UInt64 = 0
    /// Bumped when the Search text field is first bound or replaced for this window.
    @Published private(set) var searchFieldMountEpoch: UInt64 = 0

    private(set) weak var window: NSWindow?
    /// Concrete Search field bound by the scoped TextField bridge (preferred over scans).
    private(set) weak var boundSearchField: NSTextField?
    private var becomeKeyObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    /// Live AppKit key query for this host window (never a Bool captured before `await`).
    var isKeyWindow: Bool {
        window?.isKeyWindow == true
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else {
            refreshBoundSearchFieldIfNeeded()
            return
        }
        detachObservers()
        self.window = window
        boundSearchField = nil
        guard let window else {
            keyEpoch &+= 1
            return
        }

        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keyEpoch &+= 1
            }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keyEpoch &+= 1
            }
        }
        keyEpoch &+= 1
        refreshBoundSearchFieldIfNeeded()
    }

    /// Records the concrete Search field for this window and ensures its accessibility identifier.
    ///
    /// Only call from the owned Search field representable — never from a window-wide scan of
    /// unlabeled controls. Epoch publish is deferred so SwiftUI `updateNSView` never mutates
    /// `@Published` state mid-update.
    func bindSearchField(_ field: NSTextField) {
        WorkspaceSearchFieldFocus.stampSearchFieldIdentity(on: field)
        guard WorkspaceSearchFieldFocus.matchesSearchField(field) else { return }
        if boundSearchField === field {
            return
        }
        boundSearchField = field
        Task { @MainActor [weak self] in
            self?.searchFieldMountEpoch &+= 1
        }
    }

    /// Same as `bindSearchField` when the field is new, without stamping (already stamped).
    func noteIdentifierMatchedField(_ field: NSTextField) {
        guard WorkspaceSearchFieldFocus.matchesSearchField(field) else { return }
        if boundSearchField === field {
            return
        }
        boundSearchField = field
        Task { @MainActor [weak self] in
            self?.searchFieldMountEpoch &+= 1
        }
    }

    /// Bound field if still live and identifier-matched; else identifier-only hierarchy scan.
    func resolvedSearchField() -> NSTextField? {
        if let boundSearchField,
           boundSearchField.window != nil,
           WorkspaceSearchFieldFocus.matchesSearchField(boundSearchField)
        {
            return boundSearchField
        }
        return WorkspaceSearchFieldFocus.findSearchTextField(in: window?.contentView)
    }

    /// Re-discovers by accessibility identifier only (never binds unlabeled fields).
    func refreshBoundSearchFieldIfNeeded() {
        if let boundSearchField,
           boundSearchField.window != nil,
           WorkspaceSearchFieldFocus.matchesSearchField(boundSearchField)
        {
            return
        }
        boundSearchField = nil
        if let found = WorkspaceSearchFieldFocus.findSearchTextField(in: window?.contentView) {
            noteIdentifierMatchedField(found)
        }
    }

    deinit {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    private func detachObservers() {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
            self.becomeKeyObserver = nil
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
    }
}

/// Installs a zero-size AppKit probe that binds `WindowKeyStateTracker` to the hosting `NSWindow`.
struct WindowKeyStateReader: NSViewRepresentable {
    @ObservedObject var tracker: WindowKeyStateTracker

    func makeNSView(context _: Context) -> WindowKeyStateProbeView {
        let view = WindowKeyStateProbeView()
        view.tracker = tracker
        return view
    }

    func updateNSView(_ nsView: WindowKeyStateProbeView, context _: Context) {
        nsView.tracker = tracker
        if let window = nsView.window {
            tracker.attach(to: window)
        }
    }
}

final class WindowKeyStateProbeView: NSView {
    weak var tracker: WindowKeyStateTracker?

    override var intrinsicContentSize: NSSize {
        .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishHostState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        publishHostState()
    }

    override func layout() {
        super.layout()
        publishHostState()
    }

    private func publishHostState() {
        let window = window
        let tracker = tracker
        Task { @MainActor in
            tracker?.attach(to: window)
            tracker?.refreshBoundSearchFieldIfNeeded()
        }
    }
}

/// AppKit helpers that identify **only** the workspace Search query field by stable accessibility
/// identifier. Placeholder and accessibility label are display strings only — never identity.
@MainActor
enum WorkspaceSearchFieldFocus {
    static let accessibilityLabel = "Search in workspace"
    static let placeholder = "Search in workspace"
    /// Stable AppKit identity for the Search query field.
    static let accessibilityIdentifier = "plainsong.workspaceSearch.queryField"

    /// Production identity: accessibility identifier only.
    static func matchesSearchField(_ textField: NSTextField) -> Bool {
        textField.accessibilityIdentifier() == accessibilityIdentifier
    }

    /// Stamps the production identifier. Call only when constructing the owned Search field.
    static func stampSearchFieldIdentity(on textField: NSTextField) {
        if textField.accessibilityIdentifier() != accessibilityIdentifier {
            textField.setAccessibilityIdentifier(accessibilityIdentifier)
        }
    }

    /// Hierarchy scan by identifier only. Never matches unlabeled fields.
    static func findSearchTextField(in root: NSView?) -> NSTextField? {
        guard let root else { return nil }
        var match: NSTextField?
        visitTextFields(in: root) { field in
            if match == nil, matchesSearchField(field) {
                match = field
            }
        }
        return match
    }

    static func isSearchFieldFirstResponder(
        in window: NSWindow,
        expectedField: NSTextField? = nil
    ) -> Bool {
        let field = expectedField ?? findSearchTextField(in: window.contentView)
        guard let field, matchesSearchField(field) else { return false }
        guard let first = window.firstResponder else { return false }
        if let textField = first as? NSTextField {
            return textField === field
        }
        if let textView = first as? NSTextView, textView.isFieldEditor {
            return field.currentEditor() === textView
        }
        return false
    }

    @discardableResult
    static func makeSearchFieldFirstResponder(
        in window: NSWindow,
        preferredField: NSTextField? = nil
    ) -> Bool {
        let field = preferredField ?? findSearchTextField(in: window.contentView)
        guard let field, matchesSearchField(field) else {
            return false
        }
        window.makeFirstResponder(nil)
        return window.makeFirstResponder(field)
    }

    private static func visitTextFields(in root: NSView, visit: (NSTextField) -> Void) {
        if let textField = root as? NSTextField {
            visit(textField)
        }
        for subview in root.subviews {
            visitTextFields(in: subview, visit: visit)
        }
    }
}
