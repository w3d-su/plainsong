# Windows PR C gives each window a façade and routes commands through KeyWindowRouter

`docs/window-state-gates.md` §10 row C requires independent per-window state and
key-window routing while creation stays guarded. WD1, WD2, D1, and D2 stay open.

## One façade per window

Each workspace scene owns an `AppState`. A scene uses the app-owned façade whenever no
open scene shows it (`KeyWindowRouter.claimOwner`); the claim ends when that scene's
window closes, or when a reopen wait expires before the window attaches
(`docs/decisions/2026-10-29-windows-claimed-scene-attach-wait.md`). A one-time flag here made every scene after a close a refused sibling, so
the app could not get a usable window back without relaunching. The owner keeps its
document and stays registered across the close, as the single `AppState` did before C.
Closing still clears that window's external-change, missing-file, and indeterminate-write
prompts, so a closed window cannot block Save in another window. Pending external text
stays on the registry, and the next claim of the owner restores the prompts from it.
Unregistering the owner would drop an unsaved or untitled document out of the termination
inventory; that close policy stays with D2.
A scene opened while the owner is shown calls `makeSiblingFacade`, which builds a new
`WindowState` and `WorkspaceRootContext` on the existing `AppDocumentRegistry`. Closing
a sibling unregisters its window from every inventory and forgets its admission. Methods stay on
`AppState`; they were not moved onto `WindowState`. `PlainsongAppServices` is gone.
`PlainsongCommands` no longer captures an `AppState`. It asks `KeyWindowRouter` for
the target when the action runs.

The registry's Replace-authority hook and preferences callback are installed once and
fan out to every façade of that registry. The authority generation advances once.

## Admission is a side table

A second production scene is wired but not registered, and `WindowOpenAdmission`
records that its window refuses `open`, `openWorkspace`, `openWorkspaceFile`,
`newFile`, and launch restore. The flag lives beside `WindowState` so the §3.2
property inventory does not grow (`AppState` stores only its three containers, and
`WindowStatePartitionAppTests` pins that). Each entry holds its window weakly and a
missing or released entry refuses, so a reused address cannot inherit a decision.
Hosted fixtures pass `admitsFileOperations: true`, or set the DEBUG-only
`WindowOpenAdmission.testingBypass`. Release builds have no bypass and no router test
hooks. A refused scene is never home and closes itself through `KeyWindowRouter.attach`.

`openExternalFile` retargets to the frontmost admitting façade of the same registry.
An unadmitted scene cannot consume the one app-global restore attempt.

## Key window and tests

`KeyWindowRouter.menuTarget` prefers, in order: a test pin, then the key window's façade.
A key sheet or child window (an alert, an open panel) resolves through `sheetParent` or
`parent` to its workspace window. With no key window it takes the caller-supplied
façade, or the only admitting façade; with several windows it does not guess. A key
window with no façade returns nil. There is no main-window fallback.

`testingPin` exists because most hosted tests never become the process key window.
`testingUsesKeyWindowOverride` replaces `NSApp.keyWindow` when a test needs the
foreign-window and key-façade paths. Production does not set either.

Resign flushes only a façade that was attached to that window. Only a refusal the user
caused (Quit) calls `focus`, which records the window weakly and calls
`makeKeyAndOrderFront` only while the app is active. A background failure such as
autosave sets the error on its window and leaves the key window alone, so the user's
next keystroke cannot land in another document. `attach` is idempotent and its close
observer holds the façade weakly; notices hold their owner weakly too.

Termination checks image insertion in every window's root context. The shared foreground
autosave belongs to the home document: any window cancels it, and closing the home window
moves it to the per-session background task. `applicationWillTerminate` keeps one
app-global flush as a backstop.

## Close interception

`WindowCloseInterceptor` wraps whatever delegate SwiftUI already installed and
forwards every selector except `windowShouldClose`. It holds that delegate strongly
while the window is open, because `NSWindow` caches which delegate selectors exist and
a released delegate would turn one into a crash. After forwarding `windowWillClose` it
gives the window its delegate back on the next turn and lets it go. The hosted probe
uses real `performClose` calls to veto, defer, and close. Nothing sets the veto or
defer flag in production yet; closing a dirty or quarantined window is W7. Tabbing is
`.disallowed`, and `NSWindow.allowsAutomaticWindowTabbing` is set false in
`applicationWillFinishLaunching`, until PR F.

## Save enablement is a separate signal

`isSaving`, write fences, and quarantine are not `@Published`. A synchronous save used
to be able to refresh the menu while `isSaving` was true and then leave Save disabled,
because clearing the flag published nothing. Those three registry inputs, the end
of `save(session:)`, and every registry Replace-authority input `canSave` also reads
(pending external text and versions, detached URLs, reload tasks, pending editor
sources) send `menuEnablementDidChange`. `MenuBarState` re-reads `canSave`
on the next run-loop pass. The subject is app-global registry state (§3.2), not one of
the 121 properties B1 partitioned. Keystroke publishes stay on the session and are still
dropped when the snapshot does not change.
