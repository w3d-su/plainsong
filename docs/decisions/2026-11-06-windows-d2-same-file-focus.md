# WD1 runs at the two activation choke points and focuses through error presentation

- Date: 2026-11-06
- Scope: Windows PR D2; WD1 in `docs/window-state-gates.md` §4.1 and §9.1.

Every path that makes a file current in a window ends in one of two places: `open(url:)`
for path-based opens (Open…, Open Recent, Finder, the Dock, `open -a`, launch restore, the
save panel), and `prepareAnchoredFileSessionActivation` for anchored ones (Files, the jump
bar, a preview link inside the root, a Workspace Search result, reload, creation). Both
now look for another connected window whose shown document is the same file, before any
side effect: `open(url:)` before it closes this window's workspace, and the anchored
preparation before the search, reload, or commit work that follows it. Same file means the
same session, the same state URL spelling or retained location, or the same physical file
(device and inode from the retained binding or proof), so hard links and case or
normalization aliases count. A path open also treats an alias of this window's own document
as already shown and opens nothing.

A match throws `DocumentShownInAnotherWindow`. `present(_:title:)` turns that error into
`KeyWindowRouter.focusIfPossible`, so every existing `catch { present(...) }` at a user
entry point focuses the other window and shows no error. The Files deferral drops the pick,
which reverts the row. When the other window cannot come forward (it is closing, or it has a
sheet), the request refuses with "Already Open in Another Window" and neither window
changes. A reload catches the error and selects nothing, because a background refresh must
never move focus. Recovery Show Editor Copy focuses the window that shows the copy. Neither
recovery promotion nor a trash, which shows a detached copy in place of the trashed file,
picks a copy that another window shows. Warm sessions belong to no window, so a window still
adopts one that another window left (D1c).

A Finder or Dock open can reach the app before AppKit activates it. `focus` then records the
window and brings it forward when `didBecomeActive` arrives within two seconds. Hosted tests
never activate the app, so they never take the developer's key window.

Alternatives: a check in `setCurrentDocument` (rejected: it cannot throw, runs after earlier
side effects, and D1c's adoption tests call it directly with one session in two windows); a
check at each of a dozen entry points (rejected: a missed entry point would install a second
editor, while the two choke points fail closed for every caller); returning a typed result
instead of throwing (rejected: each caller's existing error path would need a new branch, and
a forgotten branch would show nothing).
