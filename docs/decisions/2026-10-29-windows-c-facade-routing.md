# Windows PR C gives each window a façade and routes commands through KeyWindowRouter

`docs/window-state-gates.md` §10 row C requires independent per-window state and
key-window routing while creation stays guarded. WD1, WD2, D1, and D2 stay open.

## One façade per window

Each workspace scene owns an `AppState`. The first scene uses the app-owned façade.
Every later scene calls `makeSiblingFacade`, which builds a new `WindowState` and
`WorkspaceRootContext` on the existing `AppDocumentRegistry`. Methods stay on
`AppState`; they were not moved onto `WindowState`. `PlainsongAppServices` is gone.
`PlainsongCommands` no longer captures an `AppState`. It asks `KeyWindowRouter` for
the target when the action runs.

The registry's Replace-authority hook and preferences callback are installed once and
fan out to every façade of that registry. The authority generation advances once.

## Admission is a side table

A second production scene is wired but not registered, and `WindowOpenAdmission`
records that its window refuses `open`, `openWorkspace`, `openWorkspaceFile`,
`newFile`, and launch restore. The flag lives beside `WindowState` so the §3.2
property inventory does not grow. Hosted fixtures set `WindowOpenAdmission.testingBypass`
or pass `admitsFileOperations: true`. That bypasses creation guards only.

`openExternalFile` retargets to the frontmost admitting façade of the same registry.
An unadmitted scene cannot consume the one app-global restore attempt.

## Key window and tests

`KeyWindowRouter.menuTarget` prefers, in order: a test pin, the key workspace window,
then the caller-supplied or first live façade when AppKit has no key window. A key
window with no façade returns nil. There is no main-window fallback.

`testingPin` exists because most hosted tests never become the process key window.
`testingUsesKeyWindowOverride` replaces `NSApp.keyWindow` when a test needs the
foreign-window and key-façade paths. Production does not set either.

Resign flushes only a façade that was attached to that window. `focus` records the
window the refusal asked to focus, and calls `makeKeyAndOrderFront` only while the
app is active, so a hosted run does not steal the owner's key window.

## Close interception

`WindowCloseInterceptor` wraps whatever delegate SwiftUI already installed and
forwards every selector except `windowShouldClose`. The hosted probe vetoes and
defers without dropping the original delegate. Full close lifecycle (W7) is still
out of scope. Tabbing is `.disallowed`, and
`NSWindow.allowsAutomaticWindowTabbing` is false, until PR F.

## Save enablement is a separate signal

`isSaving`, write fences, and quarantine are not `@Published`. A synchronous save used
to be able to refresh the menu while `isSaving` was true and then leave Save disabled,
because clearing the flag published nothing. Those three registry inputs, and the end
of `save(session:)`, send `menuEnablementDidChange`. `MenuBarState` re-reads `canSave`
on the next run-loop pass. The subject is app-global registry state (§3.2), not one of
the 121 properties B1 partitioned. Keystroke publishes stay on the session and are still
dropped when the snapshot does not change.
