import AppKit
import STTextView

/// Opaque proof of the key-window editor a Replace plan was made against.
///
/// App captures it with the plan and hands it back unchanged. Delivery compares every
/// field again, so a key-window change, remount or rebind, source revision, or selection
/// change since planning drops the command before the executor runs. No STTextView type
/// crosses this boundary.
public struct EditorReplaceEditorStamp: Equatable, Sendable {
    /// App checks owned query/replacement field composition in this exact window.
    public let window: ObjectIdentifier
    let installation: EditorDocumentBindingInstallation
    let sourceRevision: Int?
    /// App captures the raw pre-write selection for off-main batch caret mapping.
    public let selection: NSRange
}

/// One Replace command App routes to the installed editor of the key window.
@MainActor
public struct EditorReplaceCommand {
    public let request: EditorReplaceRequest
    /// App's commit decision, bound to the exact session the request describes.
    public let authorization: EditorReplaceAuthorization
    public let controller: EditorFindController
    public let editorStamp: EditorReplaceEditorStamp
    /// Live editor installations App has registered for that session. The editor the
    /// command reaches must be one of them.
    public let installations: Set<EditorDocumentBindingInstallation>

    public init(
        request: EditorReplaceRequest,
        authorization: EditorReplaceAuthorization,
        controller: EditorFindController,
        editorStamp: EditorReplaceEditorStamp,
        installations: Set<EditorDocumentBindingInstallation>
    ) {
        self.request = request
        self.authorization = authorization
        self.controller = controller
        self.editorStamp = editorStamp
        self.installations = installations
    }
}

/// Why a Replace command never reached the executor. Nothing was validated, navigated,
/// authorized, or written.
public enum EditorReplaceDeliveryRefusal: Equatable, Sendable, Error {
    case noKeyWindow
    /// The key window's responder chain holds no editor (focus is in find chrome, the
    /// query field, the sidebar, or the preview). App decides whether its fallback applies.
    case noEditorOnResponderChain
    case noEditorInKeyWindow
    /// The reached editor is not a live, installed App binding of the command's session.
    case editorNotInstalled
    /// Key window, installation, source revision, or selection changed since planning.
    case staleEditorStamp
}

public enum EditorReplaceDelivery: Equatable, Sendable {
    /// The installed key-window editor ran the Replace executor.
    case delivered(EditorReplaceOutcome)
    case notDelivered(EditorReplaceDeliveryRefusal)
}

/// Routes a plain Replace command to the installed editor in the **key** window.
///
/// Mirrors `EditorFindCommandDispatcher`: the concrete editor stays behind EditorKit, and
/// App owns the fallback for focus in the find bar chrome or query field. Unlike
/// `NSApplication.sendAction(_:to:from:)` with a `nil` target, delivery never falls through
/// to the main window or any other window: a command either reaches the key window's
/// editor or is refused (`docs/editor-replace-gates.md` §5.1).
@MainActor
public enum EditorReplaceCommandDispatcher {
    /// Stamp of the key window's installed editor, for a plan App is about to build.
    public static func captureKeyWindowEditorStamp()
        -> Result<EditorReplaceEditorStamp, EditorReplaceDeliveryRefusal>
    {
        guard let window = keyWindow else { return .failure(.noKeyWindow) }
        guard let textView = installedEditor(in: window) else {
            return .failure(.noEditorInKeyWindow)
        }
        guard let stamp = stamp(of: textView, in: window) else {
            return .failure(.editorNotInstalled)
        }
        return .success(stamp)
    }

    /// Delivery through the key window's responder chain (the editor holds focus).
    public static func send(_ command: EditorReplaceCommand) -> EditorReplaceDelivery {
        guard let window = keyWindow else { return .notDelivered(.noKeyWindow) }
        guard let textView = responderChainEditor(in: window) else {
            return .notDelivered(.noEditorOnResponderChain)
        }
        return deliver(command, to: textView, in: window)
    }

    /// App's fallback when focus is in find chrome or the owned query field: the command
    /// still reaches only the installed editor of the key window.
    public static func sendToKeyWindowEditor(
        _ command: EditorReplaceCommand
    ) -> EditorReplaceDelivery {
        guard let window = keyWindow else { return .notDelivered(.noKeyWindow) }
        guard let textView = installedEditor(in: window) else {
            return .notDelivered(.noEditorInKeyWindow)
        }
        return deliver(command, to: textView, in: window)
    }

    /// The key window, read live. Tests designate it through
    /// `EditorSelectionProbe.keyWindowOverrideForTesting`, the same seam every other
    /// EditorKit key-window entry point uses; the window must still report `isKeyWindow`.
    static var keyWindow: NSWindow? {
        // An installed override is authoritative even when it designates no key window.
        // Falling back on its nil result would leak the XCTest host's real key window.
        let candidate: NSWindow? = if let override = EditorSelectionProbe.keyWindowOverrideForTesting {
            override()
        } else {
            NSApplication.shared.keyWindow
        }
        guard let window = candidate, window.isKeyWindow
        else {
            return nil
        }
        return window
    }

    /// First editor on `window`'s responder chain, starting at its first responder.
    static func responderChainEditor(in window: NSWindow) -> STTextView? {
        var responder = window.firstResponder
        while let current = responder {
            if let textView = current as? STTextView, isPlainsongEditor(textView) {
                return textView
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// The editor mounted in `window`, regardless of first responder.
    static func installedEditor(in window: NSWindow) -> STTextView? {
        guard let root = window.contentView else { return nil }
        return editor(under: root)
    }

    private static func editor(under view: NSView) -> STTextView? {
        if let textView = view as? STTextView, isPlainsongEditor(textView) {
            return textView
        }
        for subview in view.subviews {
            if let match = editor(under: subview) {
                return match
            }
        }
        return nil
    }

    private static func isPlainsongEditor(_ textView: STTextView) -> Bool {
        textView.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
            && textView.textDelegate is MarkdownTextViewCoordinator
    }

    static func stamp(of textView: STTextView, in window: NSWindow) -> EditorReplaceEditorStamp? {
        guard textView.window === window,
              let coordinator = textView.textDelegate as? MarkdownTextViewCoordinator,
              coordinator.isPreparedDocumentInstalled,
              let installation = coordinator.currentDocumentBindingInstallation
        else {
            return nil
        }
        return EditorReplaceEditorStamp(
            window: ObjectIdentifier(window),
            installation: installation,
            sourceRevision: coordinator.currentInstalledSourceSnapshot?.revision,
            selection: textView.selectedRange()
        )
    }

    private static func deliver(
        _ command: EditorReplaceCommand,
        to textView: STTextView,
        in window: NSWindow
    ) -> EditorReplaceDelivery {
        guard let coordinator = textView.textDelegate as? MarkdownTextViewCoordinator,
              let stamp = stamp(of: textView, in: window),
              command.installations.contains(stamp.installation)
        else {
            return .notDelivered(.editorNotInstalled)
        }
        guard stamp == command.editorStamp else {
            return .notDelivered(.staleEditorStamp)
        }
        return .delivered(coordinator.performSingleReplace(
            command.request,
            authorization: command.authorization,
            controller: command.controller,
            in: textView
        ))
    }
}

@MainActor
extension MarkdownTextViewCoordinator {
    /// The exact binding/coordinator pair this editor installed, as App registered it.
    var currentDocumentBindingInstallation: EditorDocumentBindingInstallation? {
        installedDocument.installedBindingID.map {
            EditorDocumentBindingInstallation(
                bindingID: $0,
                installationID: documentBindingInstallationID
            )
        }
    }
}
