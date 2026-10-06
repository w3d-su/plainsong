import AppKit
import EditorKit
import Foundation
import MarkdownCore

/// Replacement-row intents (`docs/editor-replace-gates.md` §5.1, R8): disclosure, the owned
/// field's value, Edit ▸ Find and Replace… / Replace / Replace All, and the bar's own Replace,
/// Replace All and Cancel. Mutation still goes only through `performEditorReplace` and
/// `performEditorReplaceAll`, with every PR D–G fence; this file adds presentation and routing.
@MainActor
extension AppState {
    var editorReplaceActivity: EditorReplaceActivity {
        editorFindHost.replaceBatch.activity
    }

    /// Replace All progress reaches SwiftUI through `objectWillChange`, coalesced onto the next
    /// main turn: the runtime can change inside a representable update (an owner mount
    /// advances the authority generation), and publishing there is undefined.
    func installEditorReplacePresentationIfNeeded() {
        guard !editorFindHost.didInstallReplacePresentation else { return }
        editorFindHost.didInstallReplacePresentation = true
        editorFindHost.replaceBatch.onPresentationChange = { [weak self] in
            self?.scheduleEditorReplacePresentationPublish()
        }
    }

    private func scheduleEditorReplacePresentationPublish() {
        guard !editorFindHost.isReplacePresentationPublishPending else { return }
        editorFindHost.isReplacePresentationPublishPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            editorFindHost.isReplacePresentationPublishPending = false
            objectWillChange.send()
            announceEditorReplacePreparationIfStarted()
        }
    }

    /// Progress is a visible label VoiceOver can read at any time; its start is also spoken
    /// once per plan, without speaking each of up to 100 progress updates.
    private func announceEditorReplacePreparationIfStarted() {
        let activity = editorReplaceActivity
        guard case .preparing = activity else {
            editorFindHost.didAnnounceReplacePreparation = false
            return
        }
        guard !editorFindHost.didAnnounceReplacePreparation,
              let text = EditorReplaceStatusText.progress(activity)
        else { return }
        editorFindHost.didAnnounceReplacePreparation = true
        announceEditorReplaceStatus(text)
    }

    // MARK: - Row state

    /// Disclosure. Collapsing is a find-chrome transition: it advances the Replace authority
    /// generation (the collapse seam PR G left), so a preparing plan stops and Edit ▸ Replace
    /// / Replace All become ineligible while the retained value stays in the field.
    func setEditorReplaceExpanded(_ expanded: Bool) {
        guard editorFindHost.ui.isReplaceExpanded != expanded else { return }
        installEditorReplacePresentationIfNeeded()
        var ui = editorFindHost.ui
        ui.isReplaceExpanded = expanded
        setEditorFindUI(ui)
    }

    func toggleEditorReplaceExpanded() {
        setEditorReplaceExpanded(!editorFindHost.ui.isReplaceExpanded)
    }

    /// The replacement field's committed value (never called while it holds marked text).
    /// Runs on replacement-field edits only; editor keystrokes never reach it.
    func handleEditorReplaceTextChange(_ text: String) {
        guard !ExactSourceText.matches(editorFindHost.ui.replacementText, text) else { return }
        var ui = editorFindHost.ui
        ui.replacementText = text
        ui.replacementValidity = EditorReplacePlanning.validateReplacement(text)
        setEditorFindUI(ui)
        setEditorReplaceReplacement(text)
        clearEditorReplaceStatus()
    }

    /// Lifecycle resets and value edits drop the row's last message. The serial also makes a
    /// Replace All that finishes afterwards unable to write its stale result.
    func clearEditorReplaceStatus() {
        editorFindHost.replaceStatusSerial &+= 1
        guard editorFindHost.replaceStatus != nil else { return }
        editorFindHost.replaceStatus = nil
        objectWillChange.send()
    }

    // MARK: - Menu commands

    /// Edit ▸ Find and Replace…: ⌘F's eligibility, then expand and show/re-focus the query
    /// with select-all through the **existing** query-focus receipt. Tab or a click reaches
    /// the replacement field; it has no focus token of its own to compete with the query's.
    func showOrRefocusEditorFindAndReplace() {
        guard hasOpenDocument, isEditorFindCommandContextActive() else { return }
        setEditorReplaceExpanded(true)
        showOrRefocusEditorFind()
    }

    /// Edit ▸ Replace / Replace All: Find's key-window responder eligibility (the editor,
    /// either owned field editor, or reported first-row chrome) **and** a visible bar with an
    /// expanded row and a valid value. Delivery then reaches only the key window's editor.
    func isEditorReplaceMenuCommandEligible() -> Bool {
        hasOpenDocument
            && editorFindHost.ui.isReplaceRowActive
            && editorFindHost.ui.replacementValidity == .valid
            && isEditorFindCommandContextActive()
    }

    @discardableResult
    func performEditorReplaceMenuCommand() -> EditorReplaceCommandResult? {
        guard isEditorReplaceMenuCommandEligible() else { return nil }
        return runEditorReplace(invocation: .menu)
    }

    @discardableResult
    func performEditorReplaceAllMenuCommand() -> Bool {
        guard isEditorReplaceMenuCommandEligible() else { return false }
        return startEditorReplaceAll(invocation: .menu)
    }

    // MARK: - Bar controls

    /// The Replace button and Return in the replacement field. Like Next / Previous, the
    /// bar's own controls skip the menu's responder-context guard, but still require the row.
    @discardableResult
    func replaceFromEditorReplaceBar() -> EditorReplaceCommandResult? {
        guard hasOpenDocument, editorFindHost.ui.isReplaceRowActive,
              editorFindHost.ui.replacementValidity == .valid
        else { return nil }
        return runEditorReplace(invocation: .barControl)
    }

    @discardableResult
    func replaceAllFromEditorReplaceBar() -> Bool {
        guard hasOpenDocument, editorFindHost.ui.isReplaceRowActive,
              editorFindHost.ui.replacementValidity == .valid
        else { return false }
        return startEditorReplaceAll(invocation: .barControl)
    }

    /// Explicit Cancel while preparing; a distinct `.cancelled` result (PR G review fix 6).
    func cancelEditorReplaceAllFromBar() {
        guard editorFindHost.replaceBatch.isPreparing else { return }
        cancelEditorReplaceAll()
    }

    // MARK: - Internals

    private func runEditorReplace(invocation: EditorReplaceInvocation) -> EditorReplaceCommandResult {
        installEditorReplacePresentationIfNeeded()
        let serial = advanceEditorReplaceStatusSerial()
        let result = performEditorReplace(
            replacement: editorFindHost.ui.replacementText,
            invocation: invocation
        )
        publishEditorReplaceStatus(EditorReplaceStatusText.status(for: result), serial: serial)
        return result
    }

    /// Starts the bar's Replace All task. The plan is captured when the task first runs, one
    /// main turn later, so the task re-checks that nothing reset the row in between: a
    /// collapse, close, value edit, or lifecycle reset advances the serial and drops it.
    private func startEditorReplaceAll(invocation: EditorReplaceInvocation) -> Bool {
        installEditorReplacePresentationIfNeeded()
        let serial = advanceEditorReplaceStatusSerial()
        let replacement = editorFindHost.ui.replacementText
        editorFindHost.replaceAllTask = Task { @MainActor [weak self] in
            guard let self,
                  editorFindHost.replaceStatusSerial == serial,
                  editorFindHost.ui.isReplaceRowActive
            else { return }
            let result = await performEditorReplaceAll(replacement: replacement, invocation: invocation)
            publishEditorReplaceStatus(EditorReplaceStatusText.status(for: result), serial: serial)
        }
        return true
    }

    private func advanceEditorReplaceStatusSerial() -> UInt64 {
        editorFindHost.replaceStatusSerial &+= 1
        if editorFindHost.replaceStatus != nil {
            editorFindHost.replaceStatus = nil
            objectWillChange.send()
        }
        return editorFindHost.replaceStatusSerial
    }

    private func publishEditorReplaceStatus(_ status: EditorReplaceStatus?, serial: UInt64) {
        guard serial == editorFindHost.replaceStatusSerial, editorFindHost.ui.isReplaceRowActive else {
            return
        }
        editorFindHost.replaceStatus = status
        objectWillChange.send()
        if let status {
            announceEditorReplaceStatus(status.text)
        }
    }

    /// Spoken, not only shown: VoiceOver hears results, refusals, blocked and overflow states.
    func announceEditorReplaceStatus(_ text: String) {
        editorFindHost.lastReplaceAnnouncement = text
        let element: Any = NSApp.keyWindow.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

@MainActor
extension AppState {
    /// Escape reaching find-bar chrome through the responder chain must not close the bar
    /// while **either** owned field composes. A field editor that declines `cancelOperation:`
    /// lets the event bubble past it, so the guard is re-checked here against live AppKit
    /// state (the marked-text owner registry), never a cached flag.
    func keyWindowFindFieldIsComposing() -> Bool {
        let keyWindow: NSWindow? = if let override = editorFindHost.keyWindowOverride {
            override()
        } else {
            NSApp.keyWindow
        }
        guard let keyWindow else { return false }
        return editorFindHost.replaceMarkedTextOwners.hasMarkedText(in: ObjectIdentifier(keyWindow))
    }
}
