# An external open reuses an empty frontmost workspace window, and otherwise opens a new window

`docs/window-state-gates.md` §9 requires an answer to WD7 before D2. On 2026-10-29 the owner
chose the recommended default. Finder Open With, a Dock drop, and the other external-open
paths reuse the frontmost workspace window when it has no document and no root. Otherwise
they open a new window. Resolve that window by AppKit z-order before activation; do not
wait for `didBecomeKey`. WD1 takes precedence: an open that names a file already shown
focuses that owner. For a root that is already open, WD2 decides the context and this
rule decides the window: the chosen window attaches to the shared root context instead
of creating a second one. Exactly one window acts, and no blank scene is left behind.
D2 implements this.
Creation stays guarded until that PR. Recorded in §9.1.

Alternatives: always reusing the frontmost workspace window was rejected, because it would
replace a document the user is editing. Always opening a new window was rejected, because
an empty frontmost window should be used rather than left blank beside a second window.
