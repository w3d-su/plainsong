import EditorKitIOS
import Foundation

/// Result of dispatching an action through the scene router. Tests assert on
/// the outcome — a silent no-op and a refused dispatch must be distinguishable.
enum IOSShellActionOutcome: Equatable {
    case performed
    /// The action opens UI instead of mutating (`.find` presents the find sheet).
    case presentedSheet
    /// No authoring provider, or no current editor — nothing to route to.
    case unavailable
    /// The scene's editor does not hold command focus.
    case notFocused
    /// The provider disabled this action for the current snapshot.
    case disabled
    /// `setCommandFocus` rejected the expected binding (stale install).
    case focusRejected
}

/// Scene-scoped command routing (handoff 10). One instance per scene; receives
/// toolbar taps and hardware-keyboard shortcuts, and delivers to *this* scene's
/// currently installed editor through 08's `IOSAuthoringActionProviding`.
/// There is no app-global "active editor": a document screen that is not
/// command-focused (backgrounded scene, unfocused surface) drops the action
/// rather than retargeting it to another document — matching the macOS rule
/// that format commands no-op when focus is outside the editor.
@MainActor
final class IOSShellActionRouter: ObservableObject {
    private let scene: IOSShellSceneState

    init(scene: IOSShellSceneState) {
        self.scene = scene
    }

    /// Descriptors vended by 08; empty when the provider is unavailable.
    var actions: [IOSAuthoringAction] {
        scene.surfaces.authoring?.actions ?? []
    }

    /// Toolbar/keyboard enablement, driven by the provider's rule over the
    /// latest observed editor snapshot (nil snapshot → provider decides).
    /// The merged chrome flag vetoes first: a conflicted/unavailable/read-only
    /// document disables every source mutation regardless of snapshot staleness.
    func isEnabled(_ action: IOSAuthoringActionID) -> Bool {
        guard scene.chrome.editorCanWrite else { return false }
        guard let provider = scene.surfaces.authoring else { return false }
        return provider.isEnabled(action, snapshot: scene.editorSnapshot)
    }

    /// Route an authoring action to this scene's current editor.
    ///
    /// Gate order: present-only affordance (`find` opens the sheet) → provider
    /// and editor exist → editor holds command focus (`isFocused`, i.e. the
    /// scene-scoped route, not merely first responder) → provider enablement →
    /// synchronous `setCommandFocus` revalidation against the expected
    /// identity + bindingID. The provider still applies through
    /// `IOSSourceEditorControlling.apply`, which re-checks everything natively.
    @discardableResult
    func perform(_ action: IOSAuthoringActionID) -> IOSShellActionOutcome {
        if action == .find {
            guard scene.chrome.hasDocument else { return .unavailable }
            scene.present(.findReplace)
            return .presentedSheet
        }
        guard let provider = scene.surfaces.authoring,
              let editor = scene.currentEditor
        else {
            return .unavailable
        }
        guard let snapshot = scene.editorSnapshot, snapshot.isFocused else {
            return .notFocused
        }
        guard scene.chrome.editorCanWrite else {
            return .disabled
        }
        guard provider.isEnabled(action, snapshot: snapshot) else {
            return .disabled
        }
        guard scene.claimCommandFocus() else {
            return .focusRejected
        }
        provider.perform(action, using: editor)
        return .performed
    }

    /// Undo/redo dispatch stays with 04's native implementation; the shell
    /// only gates it on the same focus/write checks a source mutation needs.
    @discardableResult
    func undo() -> IOSShellActionOutcome {
        performEditorMutation { $0.undo() }
    }

    @discardableResult
    func redo() -> IOSShellActionOutcome {
        performEditorMutation { $0.redo() }
    }

    private func performEditorMutation(
        _ mutation: (any IOSSourceEditorControlling) -> Void
    ) -> IOSShellActionOutcome {
        guard let editor = scene.currentEditor else { return .unavailable }
        guard let snapshot = scene.editorSnapshot, snapshot.isFocused else { return .notFocused }
        guard snapshot.canWrite, scene.chrome.editorCanWrite else { return .disabled }
        guard scene.claimCommandFocus() else { return .focusRejected }
        mutation(editor)
        return .performed
    }

    // MARK: Presentation passthroughs

    func presentFrontmatter() {
        guard scene.chrome.hasDocument else { return }
        scene.present(.frontmatter)
    }

    func presentImagePicker() {
        guard scene.chrome.hasDocument else { return }
        scene.present(.imagePicker)
    }
}
