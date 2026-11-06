# Windows PR B1 stores AppState in WindowState, WorkspaceRootContext, and AppDocumentRegistry behind a forwarding façade

`docs/window-state-gates.md` §10 orders the window-state work {L, B1} → B2 → C. B1 is the
behavior-neutral first step: each `AppState` stored property moves to the container for its
§3.2 scope, and every consumer keeps reading through `AppState`. `App/AppState.swift` was 993
lines on `main` (`282a798`), 7 under SwiftLint's 1000-line error, so any feature touching it
was about to need a suppression.

All 121 stored properties now live in `WindowState` (31), `WorkspaceRootContext` (16), or
`AppDocumentRegistry` (74). `AppState` stores only the three containers and one
`AnyCancellable` array. It forwards each property under its old name, type, and access level.
Four `private(set)` properties (`layoutMode`, `wysiwygFallbackMessage`,
`editorFocusRequestID`, `isWYSIWYGMechanismHealthy`) are forwarded in `AppState.swift`, so
their setters stay file-private. Every other settable property forwards with `get` and
`_modify { yield &container.property }`. Then `map[key] = value` and `value.field = x`
mutate the container's storage in place, with no copy of a dictionary, set, or struct, and
the container's `didSet` and `@Published` run once per mutation.

The 16 Replace authority `didSet` hooks are unchanged in source
(`didSet { noteEditorReplaceAuthorityInputDidChange() }`). They now call a container method
that passes the hooked line's `#fileID`/`#line` to `AppState.noteEditorReplaceAuthorityInputDidChange`,
so the DEBUG Replace trace still names the input that changed. The three Export as HTML…
context hooks (`currentDocument`, `workspaceRootURL`, `workspaceAccess`) and the
`exportHTMLStatus` announcement keep their `oldValue` comparisons. The registry owns the one
`EditorReplaceAuthorityState` and injects it into the window's `EditorFindHost`, keeping the
generation app-global (§3.2).

An unconnected container hook fails loudly instead of open. Each of the four callbacks
(`WindowState.onEditorReplaceAuthorityInputChange` and `.onExportHTMLContextChange`,
`AppDocumentRegistry.onEditorReplaceAuthorityInputChange`, and
`WorkspaceRootContext.onExportHTMLContextChange`) defaults to `UnwiredContainerHook.report`.
In Debug builds that is an `assertionFailure` naming the callback and the hooked property's
`#fileID`/`#line`. The export hooks now pass their line too. In Release, `assertionFailure`
does nothing, so the call stays the silent no-op it was. B1 cannot reach it: only
`AppState.init` builds the containers, and it connects every hook before one can fire. But
once PR C creates more `WindowState`s, an unconnected one would skip the Replace authority
advance, and a stale Replace plan could commit. `UnwiredContainerHook.reportOverrideForTesting`
lets tests record a report instead of trapping.

`AppState` re-sends `WindowState.objectWillChange` and `AppDocumentRegistry.objectWillChange`
synchronously, so a moved `@Published` property still publishes `AppState.objectWillChange`
once, before the change. `WorkspaceRootContext` publishes nothing and is not observable.
`observeCurrentDocument` still forwards the session's publishes straight to `AppState`, so a
body edit publishes nothing beyond the session's own changes, as before. The direct `init`
signature is unchanged. Side effects keep their pre-B1 order: preferences,
layout restore, recents, then each recovery store's single `load()`, which now happens in
the registry's `init`. The containers cancel their own tasks in `deinit`, and they have no
reference cycle with `AppState`.

`AppState.swift` is 366 lines. Moves with no code changes keep it under 400: shared value
types and `RetiredWorkspaceAuthorityOwner` go to `AppStateSupportingTypes.swift`, and
open/save/restore/`canSave` go to `AppState+DocumentCommands.swift`. The layout-mode code
stays in place because draft PR #213 edits it. The one test that read a projected publisher
(`appState.$completionWorkspace`) now reads `appState.windowState.$completionWorkspace`.

Evidence: `WindowStatePartitionAppTests` and `WindowStatePartitionPublishAppTests`. They pin
the §3.2 inventory through `Mirror`. Through the façade and through the container, every one
of the 16 authority inputs advances the generation and leaves a stale plan refused at commit.
They also cover the export-context hooks, publish order and count, container release and task
cancellation, and recovery-store loading. Removing one registry `didSet`, or the registry
publish relay, fails them. `WindowStatePartitionWiringAppTests` writes every hooked input on
bare, never-connected containers and requires one report per input, each naming its own line.
It writes the same inputs on an `AppState`'s containers and requires no report. The 32-case
stale-plan test requires no report too.

Alternatives: plain `get`/`set` forwarding (rejected: every subscript write copies the
whole collection, including on the editor-publication path); moving consumers onto the
containers now (rejected: that is B2, which migrates every reader under the I2 audit); making
views observe the containers directly (rejected: it changes the subscriber surface, which is
PR C's job); a per-window Replace authority generation (rejected by §3.2: fences are
app-global); `@Observable` containers (rejected: they change when and how often SwiftUI
updates, so B1 would no longer be behavior-neutral); moving the layout-mode extension instead
of the document commands (rejected: it would conflict with #213); `preconditionFailure` for an
unconnected hook (rejected: it would stop Release builds too, which must keep the no-op); passing
the callbacks into each container's `init` (would make connecting a compile-time
requirement, but `AppState` cannot form its `[weak self]` callbacks before the containers it
stores exist, so it needs an intermediate box: left for PR C, which creates the next
containers).
