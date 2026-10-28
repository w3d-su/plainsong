import EditorKitIOS
import SwiftUI

/// Grouped settings for the behaviors iOS actually applies. The system form
/// supplies Dynamic Type, Dark Mode, and VoiceOver.
struct IOSSettingsView: View {
    @ObservedObject var preferences: IOSAppPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { preferences.editorAppearance },
                        set: { preferences.setEditorAppearance($0) }
                    )) {
                        ForEach(IOSAppPreferences.Appearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    Picker("Font", selection: Binding(
                        get: { preferences.editorFontName },
                        set: { preferences.setEditorFontName($0) }
                    )) {
                        ForEach(IOSEditorFont.availableTitles(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .accessibilityIdentifier("plainsong.ios.settings.font")
                    Picker("Theme", selection: Binding(
                        get: { preferences.editorPalette },
                        set: { preferences.setEditorPalette($0) }
                    )) {
                        ForEach(IOSEditorTheme.Palette.allCases) { palette in
                            Text(palette.settingsTitle).tag(palette)
                        }
                    }
                    .accessibilityIdentifier("plainsong.ios.settings.theme")
                    LabeledContent("Font size") {
                        Stepper(
                            value: Binding(
                                get: { preferences.editorFontSize },
                                set: { preferences.setEditorFontSize($0) }
                            ),
                            in: IOSAppPreferences.minimumEditorFontSize ... IOSAppPreferences.maximumEditorFontSize,
                            step: 1
                        ) {
                            Text("\(Int(preferences.editorFontSize)) pt")
                                .monospacedDigit()
                        }
                        .accessibilityLabel("Editor font size")
                        .accessibilityValue("\(Int(preferences.editorFontSize)) points")
                    }
                    Toggle("Line numbers", isOn: Binding(
                        get: { preferences.showsLineNumbers },
                        set: { preferences.setShowsLineNumbers($0) }
                    ))
                    .accessibilityIdentifier("plainsong.ios.settings.lineNumbers")
                    Toggle(isOn: Binding(
                        get: { preferences.typewriterSyncEnabled },
                        set: { preferences.setTypewriterSyncEnabled($0) }
                    )) {
                        Text("Typewriter sync")
                        Text("Keep the editor and preview on the same line.")
                    }
                    .accessibilityIdentifier("plainsong.ios.settings.typewriter")
                } header: {
                    Text("Editor")
                } footer: {
                    Text("Font, size, theme, and line numbers apply to the source editor.")
                    Text("Syntax colors follow the theme.")
                    Text("Typewriter sync follows the line you are reading when the preview is visible.")
                }

                Section {
                    LabeledContent("Autosave after") {
                        Stepper(
                            value: Binding(
                                get: { preferences.autosaveIntervalSeconds },
                                set: { preferences.setAutosaveIntervalSeconds($0) }
                            ),
                            in: IOSAppPreferences.minimumAutosaveIntervalSeconds ... IOSAppPreferences
                                .maximumAutosaveIntervalSeconds,
                            step: 0.5
                        ) {
                            Text("\(preferences.autosaveIntervalSeconds, specifier: "%.1f") seconds")
                                .monospacedDigit()
                        }
                        .accessibilityLabel("Autosave delay")
                        .accessibilityValue("\(preferences.autosaveIntervalSeconds, specifier: "%.1f") seconds")
                    }
                } header: {
                    Text("Saving")
                } footer: {
                    Text("Plainsong writes the current file after you pause typing for this long.")
                }

                Section {
                    Picker("Appearance", selection: Binding(
                        get: { preferences.previewAppearance },
                        set: { preferences.setPreviewAppearance($0) }
                    )) {
                        ForEach(IOSAppPreferences.Appearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    Toggle("Allow remote images", isOn: Binding(
                        get: { preferences.allowsRemoteImages },
                        set: { preferences.setAllowsRemoteImages($0) }
                    ))
                } header: {
                    Text("Preview")
                } footer: {
                    Text(
                        "Remote images load from HTTPS. Scripts and other remote content stay blocked. Export still omits remote images."
                    )
                }

                Section {
                    Picker("New file", selection: Binding(
                        get: { preferences.newFileExtension },
                        set: { preferences.setNewFileExtension($0) }
                    )) {
                        ForEach(IOSAppPreferences.NewFileExtension.allCases) { fileExtension in
                            Text(fileExtension.title).tag(fileExtension)
                        }
                    }
                    .accessibilityIdentifier("plainsong.ios.settings.newFileExtension")
                    TextField("Image folder", text: Binding(
                        get: { preferences.assetDirectoryName },
                        set: { preferences.setAssetDirectoryName($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("plainsong.ios.settings.assetDirectory")
                } header: {
                    Text("Files")
                } footer: {
                    Text(
                        "New files use this extension. Inserted images are copied into the image folder beside the document. Names that leave that folder are ignored."
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("plainsong.ios.settings.done")
                }
            }
        }
    }
}

struct IOSSettingsLink: View {
    @Environment(\.plainsongPreferences) private var preferences
    @State private var presented = false

    var body: some View {
        if let preferences {
            Button {
                presented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("plainsong.ios.settings")
            .sheet(isPresented: $presented) {
                IOSSettingsView(preferences: preferences)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

extension IOSEditorTheme.Palette {
    var settingsTitle: String {
        switch self {
        case .plainsong: "Plainsong"
        case .graphite: "Graphite"
        }
    }
}
