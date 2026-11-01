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

    /// The adopting window took the writer. When it releases that writer and exactly
    /// one earlier window still shows the session, that window can write again.
    func restoreShownWriterIfUnowned(_ session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard editorWriterInstallations[sessionIdentity] == nil else { return }
        let shown = editorBindingInstallations.filter { installation, owner in
            owner === session &&
                supersededEditorWriterInstallations.contains(installation) &&
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
