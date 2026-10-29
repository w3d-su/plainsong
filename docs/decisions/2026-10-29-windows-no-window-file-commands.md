# File commands reopen the workspace scene when no window is attached

Closing the only workspace window removed its façade from the router, and File › New
File, Open, and Open Recent call that target. They became no-ops. The system New Window
item is still replaced, because ⌘N stays New File.

Those three commands now call `openWindow(id:)` on the workspace `WindowGroup` when no
admitting façade has a window. The action runs when that scene attaches the app-owned
façade. A second command while the scene is opening joins the same queue. Several
visible windows and no key window still do not guess and do not open another window.
Save, Find, and export keep the nil target, so a closed window does not become the
command target.

A Quit refusal uses the same opener when no home window is attached, then shows the
error on the reattached owner. Session errors prefer a window that is actually showing
that session, then an attached home if the session's own window is closed. `home` no
longer falls back to a refused scene. A refused scene closes
with `close()` rather than `performClose`, so a delegate veto cannot leave the empty
window up. `attach` stays idempotent and does not ask twice.

Owner smoke still covers New File, Open, and Open Recent after closing the only
workspace window, plus Dock, Finder, `open -a`, and a refused Quit with no open window.
This does not close W0 or W2.

Alternatives: make `menuTarget` return the closed owner (rejected: Save and export
would enable against a window that is not on screen). Present a Quit refusal with
`NSAlert` instead of reopening (rejected: the error would leave the window that the
rest of the app already uses for it).
