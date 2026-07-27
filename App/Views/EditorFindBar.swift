import EditorKit
import MarkdownCore
import SwiftUI

/// Find bar chrome in the editor pane (fixed HStack shell; not NavigationSplitView).
///
/// The toggles and buttons are plain SwiftUI, so AppKit cannot tell which of them holds
/// keyboard focus — macOS flattens the bar and the editor into one hosting view. Their focus
/// is therefore reported to `AppState` through SwiftUI's own `FocusState`, purely as an
/// **observation** that keeps ⌘F / ⌘G / ⇧⌘G / ⌘E eligible while Full Keyboard Access is on
/// one of them. Focus for the query field is still *driven* by the owned AppKit
/// `NSTextField`, per the WS3C precedent against `FocusState`-driven focus.
struct EditorFindBar: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var chromeFocus: EditorFindChromeFocus?
    /// Window hosting *this* bar. Focus reports are tagged with it so a background window can
    /// neither grant eligibility in the key one nor clear the key one's live report.
    @StateObject private var windowBridge = EditorFindBarWindowBridge()

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
                markSelectAllApplied: { appState.markEditorFindSelectAllApplied($0) },
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
            .focused($chromeFocus, equals: .matchCase)
            .accessibilityIdentifier(EditorFindAccessibility.matchCase)
            .accessibilityLabel("Match case")

            Toggle(isOn: Binding(
                get: { appState.editorFindHost.ui.wholeWord },
                set: { appState.setEditorFindWholeWord($0) }
            )) {
                Image(systemName: "text.word.spacing")
            }
            .toggleStyle(.button)
            .focused($chromeFocus, equals: .wholeWord)
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
            .focused($chromeFocus, equals: .previous)
            .accessibilityIdentifier(EditorFindAccessibility.previousButton)
            .accessibilityLabel("Find previous")
            .disabled(!ui.hasActiveQuery)

            Button {
                appState.stepEditorFindFromBarControl(.next)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .focused($chromeFocus, equals: .next)
            .accessibilityIdentifier(EditorFindAccessibility.nextButton)
            .accessibilityLabel("Find next")
            .disabled(!ui.hasActiveQuery)

            // Deliberately no `.keyboardShortcut(.cancelAction)`. A key equivalent is resolved
            // before the field editor sees the event, so Escape would bypass the query field's
            // marked-text reservation and close the bar mid-IME composition instead of
            // cancelling that composition. Escape closes through the query field's
            // `doCommandBy`, which is also what `NSTextFinder`'s own bar does.
            Button("Done") {
                appState.closeEditorFindBar()
            }
            .focused($chromeFocus, equals: .done)
            .accessibilityIdentifier(EditorFindAccessibility.doneButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(EditorFindAccessibility.bar)
        // Responder-chain Escape, not a key equivalent: a key equivalent outranks the field
        // editor and would close the bar mid-IME-composition (see the Done button above).
        // This covers focus sitting on any bar control; editor focus is covered by
        // `MarkdownSTTextView.cancelOperation` through `EditorFindActionHooks.cancelFind`.
        .onExitCommand {
            appState.closeEditorFindBarFromExitCommand()
        }
        .background(EditorFindBarWindowReader(bridge: windowBridge))
        .onChange(of: chromeFocus) { _, focus in
            appState.setEditorFindChromeFocus(focus, inWindowNumber: windowBridge.windowNumber)
        }
        .onChange(of: windowBridge.windowNumber) { previous, number in
            // The window is published a turn late, so focus may already have been reported
            // against no window (dropped) or against the previous one. Re-home it.
            guard chromeFocus != nil else { return }
            appState.setEditorFindChromeFocus(nil, inWindowNumber: previous)
            appState.setEditorFindChromeFocus(chromeFocus, inWindowNumber: number)
        }
        .onDisappear {
            // Scoped: this bar unmounting must not wipe another window's live report.
            // Falls back to the last attached window because the probe may already have
            // detached (publishing `nil`) before SwiftUI runs this.
            appState.setEditorFindChromeFocus(
                nil,
                inWindowNumber: windowBridge.windowNumber ?? windowBridge.lastAttachedWindowNumber
            )
        }
    }
}
