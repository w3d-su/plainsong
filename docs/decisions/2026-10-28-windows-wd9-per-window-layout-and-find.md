# Layout mode and the Find query are per window; a new window starts with the last persisted layout

`docs/window-state-gates.md` §9 requires an answer to WD9 before PR C, which gives each
window its own state. On 2026-10-28 the owner chose the recommended default. Each window
owns its layout mode (source + preview, source only, or WYSIWYG) and its Find/Replace query.
A new window starts with the last persisted layout. As §9 states, M2's "layout restored on
relaunch" moves into the WD5 restoration records (PR E). Recorded in §9.1.

Alternatives: keeping layout mode and the Find query global, as they are today with one
shared `AppState`, was rejected. With independent windows, changing the mode or the query
in one window would rewrite every other window's, which is the mirroring G1 removes.
