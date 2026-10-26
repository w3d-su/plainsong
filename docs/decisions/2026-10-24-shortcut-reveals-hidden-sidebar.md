# ⇧⌘F reveals a hidden sidebar and opens Search there

PR #89's owner sign-off covered ⇧⌘F on the fixed `HStack` shell, whose sidebar is always
shown. #152 moved macOS 27 to a `NavigationSplitView` whose sidebar the user can hide
(View › Hide Sidebar, ⌃⌘S, or the toolbar button). `toggleWorkspaceSearch()` only changed
the shared sidebar mode, so with the sidebar hidden ⇧⌘F did nothing visible: from Files it
selected Search and asked to focus a query field that was not on screen, and from Search it
switched the invisible sidebar to Files. A hosted test written for this on 2026-10-24 timed
out waiting for the sidebar on `main` at `1428bf1`.

Now each workspace window records in `AppState.workspaceSidebarHiddenWindows` whether its
split-view sidebar is hidden (`columnVisibility == .detailOnly`, published through the
`WindowMetadataAccessor` window callback). `toggleWorkspaceSearch()` treats a hidden sidebar
in the key window as "Search is not showing", so the press focuses Search instead of
switching to Files. A search-focus request then reveals the key window's hidden sidebar
(`columnVisibility = .all`), and the existing focus loop focuses the owned query field once
it mounts. A visible Search sidebar still toggles to Files, and the `HStack` shell never
records a hidden sidebar, so its behavior is unchanged. Key-window eligibility uses
`isWorkspaceSearchFocusKeyWindow`, the same check (and test override) as query-field focus.

`WorkspaceSearchHostedActivationTests.testShortcutRevealsAHiddenSidebarAndFocusesTheQueryField`
hides the sidebar in Files mode, then again in Search mode, and requires the sidebar to
return with the query field focused each time; it then requires a visible Search sidebar to
switch to Files. With the toggle change reverted it fails on the second case.

Alternatives: reveal the sidebar in every window on any focus request (rejected: windows
share `AppState`, so a press in one window would change the others' layout); keep the
toggle and reveal only (rejected: the second case still needs two presses, the first one
changing nothing visible); always focus Search on ⇧⌘F like Xcode's Find navigator (rejected:
it changes PR #89's signed-off Search→Files toggle, which is the owner's call); inspect the
key window's `NSSplitViewController` from the hot-key handler (rejected: it depends on how
SwiftUI builds the split view).
