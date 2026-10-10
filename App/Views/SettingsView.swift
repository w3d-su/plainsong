import AppKit
import EditorKit
import SwiftUI

/// Settings window in the System Settings idiom: one tab per area, grouped forms, and
/// footers that explain what a control changes instead of separate help text.
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
                    Label("Editor", systemImage: "character.cursor.ibeam")
                }

            PreviewSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("Preview", systemImage: "eye")
                }

            FilesSettingsPane(preferences: appState.preferences)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Default folder") {
                    HStack(spacing: 8) {
                        if let folderURL = preferences.defaultFolderURL {
                            Label {
                                Text(folderURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: folderURL.path(percentEncoded: false)))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            .help(folderURL.path(percentEncoded: false))
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }

                        Menu {
                            Button("Choose…") {
                                chooseDefaultFolder()
                            }
                            Button("Clear") {
                                try? preferences.setDefaultFolderURL(nil)
                            }
                            .disabled(preferences.defaultFolderURL == nil)
                        } label: {
                            Text(preferences.defaultFolderURL == nil ? "Choose…" : "Change")
                        } primaryAction: {
                            chooseDefaultFolder()
                        }
                        .fixedSize()
                    }
                }
            } footer: {
                SettingsFooter("Open and Save panels start in this folder.")
            }

            Section {
                LabeledContent("Autosave after") {
                    HStack(spacing: 4) {
                        Text("\(preferences.autosaveIntervalSeconds, specifier: "%.1f") seconds")
                            .monospacedDigit()
                        Stepper(
                            "Autosave after",
                            value: Binding(
                                get: { preferences.autosaveIntervalSeconds },
                                set: { preferences.setAutosaveIntervalSeconds($0) }
                            ),
                            in: PlainsongPreferences.minimumAutosaveIntervalSeconds ... PlainsongPreferences
                                .maximumAutosaveIntervalSeconds,
                            step: 0.5
                        )
                        .labelsHidden()
                    }
                }
            } footer: {
                SettingsFooter("Plainsong saves automatically once you pause typing for this long.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 214)
    }

    private func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.defaultFolderURL
        panel.prompt = "Choose"

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
            Section {
                Picker("Font", selection: Binding(
                    get: { preferences.editorFontName },
                    set: { preferences.setEditorFontName($0) }
                )) {
                    ForEach(fontChoices, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }

                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        Text("\(Int(preferences.editorFontSize)) pt")
                            .monospacedDigit()
                        Stepper(
                            "Size",
                            value: Binding(
                                get: { preferences.editorFontSize },
                                set: { preferences.setEditorFontSize($0) }
                            ),
                            in: PlainsongPreferences.minimumEditorFontSize ... PlainsongPreferences
                                .maximumEditorFontSize,
                            step: 1
                        )
                        .labelsHidden()
                    }
                }

                Picker("Theme", selection: Binding(
                    get: { preferences.editorTheme },
                    set: { preferences.setEditorTheme($0) }
                )) {
                    ForEach(MarkdownEditorTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                Toggle("Show line numbers", isOn: Binding(
                    get: { preferences.showsLineNumbers },
                    set: { preferences.setShowsLineNumbers($0) }
                ))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { preferences.typewriterSyncEnabled },
                    set: { preferences.setTypewriterSyncEnabled($0) }
                )) {
                    Text("Typewriter sync")
                    Text("Keep the editor and preview scrolled to the same place.")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { preferences.experimentalWYSIWYGEnabled },
                    set: { preferences.setExperimentalWYSIWYGEnabled($0) }
                )) {
                    Text("WYSIWYG mode")
                    Text("Experimental")
                }
            } footer: {
                SettingsFooter(
                    """
                    Off by default and incomplete. Folds inline Markdown (headings, emphasis, \
                    inline code) as you type. Once enabled, cycle into it from the View menu \
                    (⌘⇧P); it falls back to source-only if the editor mechanism is unavailable. \
                    Source-only and source + preview remain the default modes.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .frame(height: 404)
    }
}

private struct PreviewSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { preferences.previewTheme },
                    set: { preferences.setPreviewTheme($0) }
                )) {
                    ForEach(PlainsongPreferences.PreviewTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
            }

            Section {
                Toggle("Allow remote images", isOn: Binding(
                    get: { preferences.allowsRemoteImages },
                    set: { preferences.setAllowsRemoteImages($0) }
                ))
            } footer: {
                SettingsFooter(
                    "Loads images from HTTPS addresses. Scripts and other remote content stay blocked."
                )
            }
        }
        .formStyle(.grouped)
        .frame(height: 196)
    }
}

private struct FilesSettingsPane: View {
    @ObservedObject var preferences: PlainsongPreferences

    var body: some View {
        Form {
            Section {
                TextField(
                    "Image folder",
                    text: Binding(
                        get: { preferences.assetFolderRelativePath },
                        set: { preferences.setAssetFolderRelativePath($0) }
                    )
                )
                .multilineTextAlignment(.trailing)
            } footer: {
                SettingsFooter("Pasted and dropped images are copied into this folder, relative to the document.")
            }

            Section {
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
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

private struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
