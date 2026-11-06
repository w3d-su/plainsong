# Native window tabs are in scope for the window-state line; PR F enables them, and PR C disallows them until then

`docs/window-state-gates.md` §9 requires an answer to WD4 before PR C, because C must know
whether to keep tab creation guarded or turn it off for good. On 2026-10-28 the owner chose
the recommended default. Native macOS window tabs, where each tab is a window (goal G5), are
part of this line. PR F enables them with `.automatic` tabbing and ⌘T (New Tab). F waits for
D2's guarded routing, and W0 must first prove that New Tab joins the key window's group.
Until F lands, PR C sets tabbing to disallowed. It also disables, or routes to the existing
window, every other second-window path from W0 bullet 1, so a tab can never mirror another
window's document. Recorded in §9.1.

Alternatives: deferring tabs to a later line, with tabbing disallowed and no PR F, was
rejected. Several posts of one blog open as tabs is the main use of multiple windows (§4.2),
and C needs the same tab guard either way.
