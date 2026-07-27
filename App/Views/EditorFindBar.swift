import EditorKit
import MarkdownCore
import SwiftUI

/// Find bar chrome in the editor pane (fixed HStack shell; not NavigationSplitView).
struct EditorFindBar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let ui = appState.editorFindHost.ui

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            EditorFindQueryField(
                text: Binding(
                    get: { appState.editorFindHost.ui.queryText },
                    set: { appState.handleEditorFindQueryTextChange($0) }
                ),
                focusRequestID: ui.focusRequestID,
                selectAllRequestID: ui.selectAllRequestID,
                isEnabled: true,
                onSubmit: {
                    appState.editorFindNext()
                },
                onEscape: {
                    appState.closeEditorFindBar()
                }
            )
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
            .frame(height: 24)

            Toggle(isOn: Binding(
                get: { appState.editorFindHost.ui.matchCase },
                set: { appState.setEditorFindMatchCase($0) }
            )) {
                Text("Aa")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .accessibilityIdentifier(EditorFindAccessibility.matchCase)
            .accessibilityLabel("Match case")

            Toggle(isOn: Binding(
                get: { appState.editorFindHost.ui.wholeWord },
                set: { appState.setEditorFindWholeWord($0) }
            )) {
                Image(systemName: "text.word.spacing")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier(EditorFindAccessibility.wholeWord)
            .accessibilityLabel("Whole word")

            if ui.hasActiveQuery {
                Text(ui.matchCounterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(EditorFindAccessibility.matchCounter)
                    .accessibilityLabel("Find match counter")
                    .accessibilityValue(ui.matchCounterText)

                if ui.isTruncated {
                    Label("Truncated", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(EditorFindAccessibility.truncatedIndicator)
                        .accessibilityLabel("Results truncated at match ceiling")
                }
            }

            Button {
                appState.editorFindPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(EditorFindAccessibility.previousButton)
            .accessibilityLabel("Find previous")
            .disabled(!ui.hasActiveQuery)

            Button {
                appState.editorFindNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(EditorFindAccessibility.nextButton)
            .accessibilityLabel("Find next")
            .disabled(!ui.hasActiveQuery)

            Button("Done") {
                appState.closeEditorFindBar()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(EditorFindAccessibility.doneButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(EditorFindAccessibility.bar)
    }
}
