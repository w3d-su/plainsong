# A workspace reopen that never attaches can be tried again

`docs/decisions/2026-10-29-windows-no-window-file-commands.md` opens the workspace
scene when New File, Open, Open Recent, or a Quit refusal has no window. That open
used one flag, cleared only when the app-owned façade attached. If `openWindow`
produced no window, or launch never created the first scene, every later command
only queued. A Dock reopen then ran the whole queue: several Open panels, several
New Files, or a stale Quit error.

File commands now keep only the latest action. Quit errors stay in a separate list,
so an Open does not drop a refusal and a refusal does not drop the Open. One open
attempt waits three seconds. If the owner has not attached, the wait ends, both
lists are dropped, and the next command may open the scene again. Further commands
during that wait do not extend it. After launch, a waiting command requests a scene
only if no scene has claimed the owner. Tracking the façade happens before any
scene exists, and a claimed scene may still be waiting for its window to attach.
The distinction and timeout retry are recorded in
`docs/decisions/2026-10-29-windows-claimed-scene-attach-wait.md`.

With exactly one workspace window, those three commands still run when Settings or
About is key. That is an exception to `menuTarget`, which returns nil for a
non-workspace key window so Save, Find, and export stay disabled. The command
brings the workspace window forward first, so the new file or Open panel is not
left behind Settings. Several workspace windows and no key window still do not guess.

Alternatives: keep every queued command (rejected: a stuck open replays all of them
at once). Reset the three-second wait on each key repeat (rejected: repeating the
shortcut would postpone recovery forever). Present the Quit refusal with `NSAlert`
when the reopen expires (rejected: the expired attempt is discarded; the next Quit
asks again). Fall back to the closed owner from `menuTarget` (rejected: Save and
export would enable against a window that is not on screen).
