import EditorKit
import Foundation
import MarkdownCore

@MainActor
extension AppState {
    var editorInstallationWindows: [EditorDocumentBindingInstallation: RegisteredWindowState] {
        get { registry.editorInstallationWindows }
        _modify { yield &registry.editorInstallationWindows }
    }

    var supersededEditorWriterInstallations: Set<EditorDocumentBindingInstallation> {
        get { registry.supersededEditorWriterInstallations }
        _modify { yield &registry.supersededEditorWriterInstallations }
    }

    /// Adoption, installation, and teardown only. Publication still checks the one
    /// registry writer in O(1); no window enumeration is added to a keystroke.
    func transferEditorWriterForAdoption(of session: DocumentSession) {
        for (installation, owner) in editorBindingInstallations where owner === session {
            guard let oldWindow = editorInstallationWindows[installation]?.window,
                  oldWindow !== windowState
            else { continue }
            supersededEditorWriterInstallations.insert(installation)
            if editorWriterInstallations[ObjectIdentifier(session)] == installation {
                editorWriterInstallations[ObjectIdentifier(session)] = nil
            }
        }
    }

    /// A released writer can reactivate or retry a stale revision until its binding
    /// is revoked. Restore an earlier window only after the last eligible binding leaves.
    func restoreShownWriterIfUnowned(_ session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard editorWriterInstallations[sessionIdentity] == nil else { return }
        let installed = editorBindingInstallations.filter { $0.value === session }
        guard installed.keys.allSatisfy(supersededEditorWriterInstallations.contains) else { return }
        let shown = installed.filter { installation, _ in
            editorInstallationWindows[installation]?.window?.shownSession === session
        }
        guard shown.count == 1, let installation = shown.keys.first else { return }
        supersededEditorWriterInstallations.remove(installation)
        editorWriterInstallations[sessionIdentity] = installation
        assertSingleCrossWindowEditorInstallation(for: session)
    }

    func assertSingleCrossWindowEditorInstallation(for session: DocumentSession) {
        #if DEBUG
            var windows: Set<ObjectIdentifier> = []
            for (installation, owner) in editorBindingInstallations where owner === session {
                guard !supersededEditorWriterInstallations.contains(installation),
                      let window = editorInstallationWindows[installation]?.window
                else { continue }
                windows.insert(ObjectIdentifier(window))
            }
            if windows.count > 1 {
                assertionFailure(
                    "A session has non-superseded editor installations in \(windows.count) windows"
                )
            }
        #endif
    }
}
