import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorThemeSettings: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Picker("Theme", selection: Binding(
            get: { preferences.editorThemeIdentifier },
            set: { preferences.selectEditorTheme(identifier: $0) }
        )) {
            Section("Built-in") {
                ForEach(preferences.builtInEditorThemeChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            if !preferences.importedEditorThemeChoices.isEmpty {
                Section("Imported") {
                    ForEach(preferences.importedEditorThemeChoices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
            }
        }

        HStack {
            Button("Import Theme…") {
                importTheme()
            }
            Button("Reveal in Finder") {
                preferences.revealSelectedEditorTheme()
            }
            .disabled(!preferences.canManageSelectedEditorThemeFile)
            Button("Remove") {
                removeSelectedTheme()
            }
            .disabled(!preferences.canManageSelectedEditorThemeFile)
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try preferences.importEditorTheme(from: url)
        } catch {
            EditorThemeFailureAlert.make(messageText: "Could not import theme", error: error).runModal()
        }
    }

    private func removeSelectedTheme() {
        do {
            _ = try preferences.removeSelectedEditorTheme()
        } catch {
            EditorThemeFailureAlert.make(messageText: "Could not remove theme", error: error).runModal()
        }
    }
}

@MainActor
enum EditorThemeFailureAlert {
    static func make(messageText: String, error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = error.localizedDescription
        return alert
    }
}
