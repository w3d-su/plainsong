import AppKit
import EditorKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            EditorSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }

            PreviewSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("Preview", systemImage: "sidebar.right")
                }

            FilesSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("Files", systemImage: "doc")
                }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            LabeledContent("Default folder") {
                HStack {
                    Text(preferences.defaultFolderURL?.path(percentEncoded: false) ?? "None")
                        .foregroundStyle(preferences.defaultFolderURL == nil ? .secondary : .primary)
                        .lineLimit(1)

                    Button("Choose...") {
                        chooseDefaultFolder()
                    }

                    Button("Clear") {
                        try? preferences.setDefaultFolderURL(nil)
                    }
                    .disabled(preferences.defaultFolderURL == nil)
                }
            }

            LabeledContent("Autosave interval") {
                Stepper(
                    "\(preferences.autosaveIntervalSeconds, specifier: "%.1f") s",
                    value: Binding(
                        get: { preferences.autosaveIntervalSeconds },
                        set: { preferences.setAutosaveIntervalSeconds($0) }
                    ),
                    in: PlainsongPreferences.minimumAutosaveIntervalSeconds ... PlainsongPreferences
                        .maximumAutosaveIntervalSeconds,
                    step: 0.5
                )
                .frame(width: 120)
            }
        }
    }

    private func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.defaultFolderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? preferences.setDefaultFolderURL(url)
    }
}

private struct EditorSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    private let fontChoices = [
        MarkdownSyntaxHighlighter.systemMonospacedFontName,
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier New",
    ]

    var body: some View {
        Form {
            Picker("Font", selection: Binding(
                get: { preferences.editorFontName },
                set: { preferences.setEditorFontName($0) }
            )) {
                ForEach(fontChoices, id: \.self) { fontName in
                    Text(fontName).tag(fontName)
                }
            }

            LabeledContent("Font size") {
                Stepper(
                    "\(Int(preferences.editorFontSize)) pt",
                    value: Binding(
                        get: { preferences.editorFontSize },
                        set: { preferences.setEditorFontSize($0) }
                    ),
                    in: PlainsongPreferences.minimumEditorFontSize ... PlainsongPreferences.maximumEditorFontSize,
                    step: 1
                )
                .frame(width: 120)
            }

            Picker("Theme", selection: Binding(
                get: { preferences.editorTheme },
                set: { preferences.setEditorTheme($0) }
            )) {
                ForEach(MarkdownEditorTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }

            Toggle("Line numbers", isOn: Binding(
                get: { preferences.showsLineNumbers },
                set: { preferences.setShowsLineNumbers($0) }
            ))

            Toggle("Typewriter sync", isOn: Binding(
                get: { preferences.typewriterSyncEnabled },
                set: { preferences.setTypewriterSyncEnabled($0) }
            ))

            Toggle("WYSIWYG mode (Experimental)", isOn: Binding(
                get: { preferences.experimentalWYSIWYGEnabled },
                set: { preferences.setExperimentalWYSIWYGEnabled($0) }
            ))

            Text(
                """
                Off by default and incomplete. Folds inline Markdown (headings, emphasis, \
                inline code) as you type. Once enabled, cycle into it from the View menu \
                (⌘⇧P); it falls back to source-only if the editor mechanism is unavailable. \
                Source-only and source + preview remain the default modes.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PreviewSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            Picker("Theme", selection: Binding(
                get: { preferences.previewTheme },
                set: { preferences.setPreviewTheme($0) }
            )) {
                ForEach(PlainsongPreferences.PreviewTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }

            Toggle("Allow remote images", isOn: Binding(
                get: { preferences.allowsRemoteImages },
                set: { preferences.setAllowsRemoteImages($0) }
            ))
        }
    }
}

private struct FilesSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            TextField(
                "Asset folder",
                text: Binding(
                    get: { preferences.assetFolderRelativePath },
                    set: { preferences.setAssetFolderRelativePath($0) }
                )
            )

            Picker("Default extension", selection: Binding(
                get: { preferences.defaultFileExtension },
                set: { preferences.setDefaultFileExtension($0) }
            )) {
                ForEach(PlainsongPreferences.DefaultFileExtension.allCases) { fileExtension in
                    Text(fileExtension.displayName).tag(fileExtension)
                }
            }
        }
    }
}
