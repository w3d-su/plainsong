# A window decides its close in windowShouldClose and keeps no document afterwards

- Date: 2026-11-06
- Scope: Windows PR D2; §6.2 and WD8 in `docs/window-state-gates.md`.

`WindowCloseInterceptor` asks the wrapped SwiftUI delegate first, and then the window's
`approveWindowClose`. Everything that can fail happens there, while AppKit can still keep the
window open:

1. Transient work refuses the close: pending editor source (which covers marked text), a save
   or a read of the file in flight, a namespace mutation, or an image insertion in this
   window. So does quarantine: an indeterminate write, a mutation quarantine, or a write
   fence. The user closes again once the work settles. WD8 allows refusing or deferring;
   refusing keeps the window's state exactly as it was, and no timer can close it later.
2. A dirty document that can be saved is saved. A failed save keeps the window open.
3. A dirty document that cannot be saved closes only with registry retention proof: it is a
   text-recovery copy, or it is warm at its state URL with a retained location and with the
   state its prompt is rebuilt from (a missing file or a change on disk). The LRU cannot drop
   it while it is dirty, because eviction saves first and that save is refused. Otherwise the
   close is refused. An untitled document has no URL, so it can never be warm and always
   refuses.
4. The last window on a root runs D1b's release, which preflights, saves, and may refuse. Any
   other window leaves the shared root (D1c).

`willClose` then finishes the close and cannot fail. It revokes this window's editor
installations and releases its writer, instead of waiting for SwiftUI to dismantle the
editor. It leaves the registry inventories, so the LRU counts the window's document again and
trims (§6.2 step 3). It cancels the window's search, completion, Find, and navigation work,
and invalidates its preview controllers (step 5).

Every window keeps no document after it closes, the app-owned one included. The app-owned
façade stays alive and admitted. Its next scene (a Dock reopen, a file command with no
window, or New Window) is an empty window and rejoins the inventories. A closed session
stays warm, and its prompt comes back when a window shows the file again. This replaces C's
rule that the owner keeps its document across a close: under WD8 nothing a close keeps
depends on the owner staying registered, and ⇧⌘N must open an empty window (W8).

Replacing the save group had also removed File › Close, so ⌘W closed nothing. Close comes
back and reaches the key window through the responder chain, like the system item, so
Settings and About still close with ⌘W.

Alternatives: saving and releasing in `willClose` (rejected: a failure there cannot keep the
window, so a failed save or refused release would be lost); deferring transient closes and
retrying (rejected for D2: a retry timer could close a window the user went back to, and
the work settles in milliseconds); keeping the owner's document across a close (rejected:
⇧⌘N after the last close would reopen it, and a closed window would still count its document
as installed).
