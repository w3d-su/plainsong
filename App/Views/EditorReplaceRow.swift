import EditorKit
import MarkdownCore
import SwiftUI

/// The disclosed second row of the find bar (`docs/editor-replace-gates.md` §5.1).
///
/// Every state is text plus a symbol, never color alone, and each has a stable
/// `plainsong.editorFind.*` identifier. The buttons are owned AppKit controls
/// (`EditorFindBarButton`) that call App intents directly, as Next / Previous / Done do. They
/// stay enabled while a plan prepares, so a focused button never loses focus mid-action; a
/// second Replace All supersedes the first, as in PR G.
struct EditorReplaceRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let ui = appState.editorFindHost.ui
        let activity = appState.editorReplaceActivity
        let status = appState.editorFindHost.replaceStatus
        let fieldError = EditorReplaceStatusText.fieldError(ui.replacementValidity)
        let actionsDisabled = !ui.hasActiveQuery || fieldError != nil

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
                onSubmit: { appState.replaceFromEditorReplaceBar() },
                onEscape: { appState.closeEditorFindBar() },
                onOwnerMount: { field in
                    appState.editorFindHost.replaceMarkedTextOwners.register(field)
                    appState.advanceEditorReplaceAuthorityGeneration()
                },
                onOwnerUnmount: { field in
                    appState.editorFindHost.replaceMarkedTextOwners.unregister(field)
                    appState.advanceEditorReplaceAuthorityGeneration()
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
                isEnabled: !actionsDisabled
            ) {
                appState.replaceFromEditorReplaceBar()
            }
            .fixedSize()

            EditorFindBarButton(
                title: "Replace All",
                identifier: EditorFindAccessibility.replaceAllButton,
                accessibilityHelp: "Replaces every match in this document as one undo step",
                isEnabled: !actionsDisabled
            ) {
                appState.replaceAllFromEditorReplaceBar()
            }
            .fixedSize()

            activityView(activity)

            if activity == .idle {
                statusView(status)
            }

            if ui.hasActiveQuery, ui.isTruncated || status?.kind == .overflow {
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
                    accessibilityLabel: "Cancel Replace All"
                ) {
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
                symbol("lock")
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
