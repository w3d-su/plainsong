import AppKit
import EditorKit
import MarkdownCore
import SwiftUI

/// Everything the replacement row displays, as one comparable value.
struct EditorReplaceRowModel: Equatable {
    let replacementText: String
    let replacementValidity: EditorReplaceValueValidity
    let hasActiveQuery: Bool
    let isTruncated: Bool
    let activity: EditorReplaceActivity
    let status: EditorReplaceStatus?

    @MainActor
    init(appState: AppState) {
        let ui = appState.editorFindHost.ui
        replacementText = ui.replacementText
        replacementValidity = ui.replacementValidity
        // The session is nil while matches recompute — including the recount inside a
        // committed Replace — so a session-derived flag would flap disabled and force a
        // focused row button to resign first responder mid-action. The committed query is
        // stable across recomputes, matching menu eligibility (`isReplaceRowActive` never
        // consults session state either).
        hasActiveQuery = appState.editorFindHost.controller.query.map { !$0.pattern.isEmpty }
            ?? false
        isTruncated = ui.isTruncated
        activity = appState.editorReplaceActivity
        status = appState.editorFindHost.replaceStatus
    }
}

/// The disclosed second row of the find bar (`docs/editor-replace-gates.md` §5.1).
///
/// Every state is text plus a symbol, never color alone, and each has a stable
/// `plainsong.editorFind.*` identifier. The buttons are owned AppKit controls
/// (`EditorFindBarButton`) that call App intents directly, as Next / Previous / Done do. They
/// stay enabled while a plan prepares, so a focused button never loses focus mid-action; a
/// second Replace All supersedes the first, as in PR G.
///
/// The row is an `Equatable` view over `EditorReplaceRowModel` and deliberately does not
/// observe `AppState`: unrelated publishes (editor keystrokes among them) compare one small
/// value and never re-evaluate the row or update its AppKit views.
struct EditorReplaceRow: View, Equatable {
    let model: EditorReplaceRowModel
    /// Intents only; never read for display.
    let appState: AppState

    nonisolated static func == (lhs: EditorReplaceRow, rhs: EditorReplaceRow) -> Bool {
        lhs.model == rhs.model && lhs.appState === rhs.appState
    }

    var body: some View {
        let activity = model.activity
        let status = model.status
        let fieldError = EditorReplaceStatusText.fieldError(model.replacementValidity)
        let actionsDisabled = !model.hasActiveQuery || fieldError != nil

        HStack(spacing: 8) {
            // Aligns the field under the query field (disclosure + magnifier column).
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            EditorReplaceField(
                text: Binding(
                    get: { appState.editorFindHost.ui.replacementText },
                    set: { appState.handleEditorReplaceTextChange($0) }
                ),
                errorText: fieldError,
                onSubmit: { window in appState.replaceFromEditorReplaceBar(in: window) },
                onEscape: { appState.closeEditorFindBar() },
                onOwnerMount: { field in
                    appState.editorFindHost.replaceMarkedTextOwners.register(field)
                    appState.advanceEditorReplaceAuthorityGeneration()
                },
                onOwnerUnmount: { field in
                    appState.editorFindHost.replaceMarkedTextOwners.unregister(field)
                    appState.advanceEditorReplaceAuthorityGeneration()
                },
                onRemovalWhileFocused: { window in
                    appState.handOffEditorReplaceFocus(
                        fromRemoved: EditorFindAccessibility.replacementField, in: window
                    )
                }
            )
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
            .frame(height: 24)

            if let fieldError {
                symbol("exclamationmark.circle")
                EditorFindBarLabel(text: fieldError, identifier: EditorFindAccessibility.replacementFieldError)
            }

            EditorFindBarButton(
                title: "Replace",
                identifier: EditorFindAccessibility.replaceButton,
                accessibilityHelp: "Replaces the current match and moves to the next",
                isEnabled: !actionsDisabled,
                onRemovalWhileFocused: handOff(EditorFindAccessibility.replaceButton),
                onEscape: escape
            ) { window in
                appState.replaceFromEditorReplaceBar(in: window)
            }
            .fixedSize()

            EditorFindBarButton(
                title: "Replace All",
                identifier: EditorFindAccessibility.replaceAllButton,
                accessibilityHelp: "Replaces every match in this document as one undo step",
                isEnabled: !actionsDisabled,
                onRemovalWhileFocused: handOff(EditorFindAccessibility.replaceAllButton),
                onEscape: escape
            ) { window in
                appState.replaceAllFromEditorReplaceBar(in: window)
            }
            .fixedSize()

            activityView(activity)

            if activity == .idle {
                statusView(status)
            }

            if model.hasActiveQuery, model.isTruncated || status?.kind == .overflow {
                symbol("exclamationmark.triangle")
                EditorFindBarLabel(
                    text: EditorReplaceStatusText.overflow,
                    identifier: EditorFindAccessibility.replaceOverflow
                )
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(EditorFindAccessibility.replaceRow)
    }

    private var escape: () -> Void {
        { [appState] in appState.closeEditorFindBarFromExitCommand() }
    }

    private func handOff(_ identifier: String) -> (NSWindow) -> Void {
        { [appState] window in appState.handOffEditorReplaceFocus(fromRemoved: identifier, in: window) }
    }

    /// Decorative: the adjacent label's text carries the whole meaning.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func activityView(_ activity: EditorReplaceActivity) -> some View {
        if let text = EditorReplaceStatusText.progress(activity) {
            symbol(activity == .applying ? "hourglass" : "clock.arrow.circlepath")
            EditorFindBarLabel(
                text: text,
                identifier: EditorFindAccessibility.replaceProgress,
                isSecondary: true
            )
            // Commit is synchronous and non-cancellable, so Cancel exists only while preparing.
            if case .preparing = activity {
                EditorFindBarButton(
                    title: "Cancel",
                    identifier: EditorFindAccessibility.replaceCancelButton,
                    accessibilityLabel: "Cancel Replace All",
                    onRemovalWhileFocused: handOff(EditorFindAccessibility.replaceCancelButton),
                    onEscape: escape
                ) { _ in
                    // Cancel has no mutation to protect, so a press in any window may stop
                    // the shared plan; only Replace and Replace All require the key window.
                    appState.cancelEditorReplaceAllFromBar()
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func statusView(_ status: EditorReplaceStatus?) -> some View {
        switch status?.kind {
        case .blocked?:
            if let status {
                // The autosave's own disk inspection is momentary: a clock, not a lock.
                symbol(status.isTransient ? "clock" : "lock")
                EditorFindBarLabel(text: status.text, identifier: EditorFindAccessibility.replaceBlockedReason)
            }
        case .result?, .refusal?:
            if let status {
                symbol(status.kind == .result ? "checkmark.circle" : "info.circle")
                EditorFindBarLabel(text: status.text, identifier: EditorFindAccessibility.replaceStatus)
            }
        case .overflow?, nil:
            // Overflow has its own persistent label above.
            EmptyView()
        }
    }
}
