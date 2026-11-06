import MarkdownCore
import SwiftUI
import WorkspaceCore

struct IOSWorkspaceSearchSheet: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject private var search: IOSWorkspaceSearchController
    @FocusState private var queryFocused: Bool

    init(scene: IOSShellSceneState) {
        self.scene = scene
        _search = ObservedObject(wrappedValue: scene.workspaceSearch)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                queryControls
                Text(search.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(search.statusText)
                    .accessibilityIdentifier("plainsong.ios.search.status")
                results
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .navigationTitle("Search in Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { scene.dismissPresentation() }
                        .frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            queryFocused = true
            scene.refreshWorkspaceSearch()
        }
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find in folder", text: Binding(
                get: { search.queryText },
                set: { scene.updateWorkspaceSearchQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($queryFocused)
            .accessibilityLabel("Find in folder")
            .accessibilityIdentifier("plainsong.ios.search.query")
            .onSubmit { scene.refreshWorkspaceSearch() }
            Picker("Case", selection: Binding(
                get: { search.caseSensitivity },
                set: { scene.updateWorkspaceSearchCase($0) }
            )) {
                Text("Smart").tag(TextSearchCaseSensitivity.smart)
                Text("Sensitive").tag(TextSearchCaseSensitivity.sensitive)
                Text("Insensitive").tag(TextSearchCaseSensitivity.insensitive)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Search case")
            Toggle("Whole Word", isOn: Binding(
                get: { search.wholeWord },
                set: { scene.updateWorkspaceSearchWholeWord($0) }
            ))
            .accessibilityLabel("Whole Word")
        }
    }

    private var results: some View {
        List {
            ForEach(search.sections) { section in
                Section(section.relativePath) {
                    ForEach(section.hits) { hit in
                        Button {
                            scene.openWorkspaceSearchHit(hit, in: section)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Line \(hit.line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(highlightedPreview(hit))
                                    .font(.body)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(section.relativePath), line \(hit.line). \(hit.preview)")
                        .accessibilityHint("Opens the match")
                        .accessibilityAddTraits(.isButton)
                    }
                    if section.truncated {
                        Text("More matches in this file were not shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func highlightedPreview(_ hit: IOSWorkspaceSearchHit) -> AttributedString {
        guard let range = Range(hit.previewMatchRange, in: hit.preview) else {
            return AttributedString(hit.preview)
        }
        var result = AttributedString(hit.preview[..<range.lowerBound])
        var match = AttributedString(hit.preview[range])
        match.inlinePresentationIntent = .stronglyEmphasized
        result += match
        result += AttributedString(hit.preview[range.upperBound...])
        return result
    }
}
