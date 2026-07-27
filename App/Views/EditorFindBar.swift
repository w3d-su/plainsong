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
                isEnabled: true,
                readFocusSnapshot: { appState.editorFindHost.ui.focusSnapshot },
                markFocusApplied: { appState.markEditorFindFocusApplied($0) },
                onSubmit: {
                    // Bar chrome acts directly: the responder-context guard exists to keep
                    // *menu* commands from firing when focus is elsewhere in the window.
                    appState.stepEditorFindFromBarControl(.next)
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

            // Always reserve counter chrome so first-match appearance does not reflow
            // the HStack and remount the AppKit query field (which would drop focus).
            Text(ui.hasActiveQuery ? ui.matchCounterText : " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
                .opacity(ui.hasActiveQuery ? 1 : 0)
                .accessibilityIdentifier(EditorFindAccessibility.matchCounter)
                .accessibilityLabel("Find match counter")
                .accessibilityValue(ui.hasActiveQuery ? ui.matchCounterText : "")
                .accessibilityHidden(!ui.hasActiveQuery)

            if ui.hasActiveQuery, ui.isTruncated {
                Label("Truncated", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(EditorFindAccessibility.truncatedIndicator)
                    .accessibilityLabel("Results truncated at match ceiling")
            }

            Button {
                appState.stepEditorFindFromBarControl(.previous)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(EditorFindAccessibility.previousButton)
            .accessibilityLabel("Find previous")
            .disabled(!ui.hasActiveQuery)

            Button {
                appState.stepEditorFindFromBarControl(.next)
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
