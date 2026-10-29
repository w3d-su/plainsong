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
}
