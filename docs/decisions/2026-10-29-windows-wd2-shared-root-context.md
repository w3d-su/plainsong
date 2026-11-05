# One shared, reference-counted root context per canonical root, with the §4.3 overlap refusals

`docs/window-state-gates.md` §9 requires an answer to WD2 before D1. On 2026-10-29 the owner
chose the recommended default. Each canonical workspace root has one `WorkspaceRootContext`,
reference-counted by the windows that show it: one security-scope start, one watcher, and
one scan snapshot and generation per refresh. Each window still owns its filtered tree,
Show All Files, expansion, selection, reload disposition, and search. Two independent
contexts for one root are never allowed (§4.2 iv). §4.3 is part of this decision. Opening
a folder that overlaps a root open in another window (an ancestor or a descendant) is
refused, and opening a root that contains a file already installed as a standalone file in
another window is refused before that root is installed. Both refusals offer to show the
other window. Routing a single file that lies inside an open root is WD1 and WD7, and it
stays with D2; this decision does not implement it. D1c builds the shared context and the
refusals. D1b scopes last-root release to that root. Recorded in §9.1.

Alternatives: focusing the existing window for the same root (ii) was rejected. One window
per root rules out several posts of one blog as tabs, the main use of multiple windows
under WD4. Refusing a second window on the same root (iii) was rejected as hostile.
Independent duplicate contexts (iv) stay forbidden, because a rename in one window would
not fence the other window's session (I4).
