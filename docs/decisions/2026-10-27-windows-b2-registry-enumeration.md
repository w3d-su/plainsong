# Windows PR B2 takes every session inventory from one registry enumerator over every connected window

`docs/window-state-gates.md` §3.4 I2 requires every ownership inventory to span all windows.
On `main` (`a210f85`) about 25 sites in 12 files built their own lists. Each wrote some
mix of `[currentDocument]`, `sessionCache.values`, retired sessions, editor bindings,
installations, and recovery sessions, with its own order and filters. A session that only a
second window showed would have been missed by all of them.

`AppDocumentRegistry+Sessions.swift` now holds the only enumerator,
`sessions(from: [RegistrySessionSource])`. Each inventory lists its sources in the order it
used before, and each session appears once. `windowDocuments` and
`fileBackedWindowDocuments` read every connected window's `shownSession`, so the "include
the current document only when it has a file" filters survive per inventory. The
`mutationRecovery` source replaces the separate `workspaceMutationRetainedRecoverySessions()`
list.

These all use the enumerator now:
- autosave flush,
- termination,
- Save Copy candidates,
- mutation-managed sessions,
- workspace closure,
- external-conflict and retained-authority collision checks,
- physical-duplicate detection,
- metadata pruning,
- LRU protection,
- search overlays and the scan's retained paths.

The membership checks use `isShownByAnyWindow` and the warm-cache predicates instead of
`session === currentDocument`: `canAutosave`, `isManagedEditorSession`, external-resolution
addressability, `releaseUnreferencedSessionOwnership`, retired-metadata cleanup, and
relevant-edit search restart.

Every `sessionCache` read and write moved behind the registry's warm-cache API.
`sessionCache` now appears only in `AppDocumentRegistry` and its `+Sessions` extension, and
the `AppState.sessionCache` forwarder is gone. Tests read `appState.registry.sessionCache`, a
mechanical rename.

`AppState.connect(_:)` wires a `WindowState`'s hooks and then registers it, so no window can
receive input before its hooks are connected (`UnwiredContainerHook`). In B2 only the shared
window and test fixtures are connected.

The per-file save and autosave gate consults every connected window's prompts (§3.4 I3) through
`isSaveBlockedByWindowPrompt(at:)`. In a single window it reads the same prompts as before.

**How B2 reads I2 (owner decision, 2026-10-28).** I2 as first written said that after B2
nothing outside `WindowState` reads `currentDocument`. The code splits those reads into two
kinds:
- About 25 inventory and membership uses. These are what I2 protects, and B2 moved them all to
  the enumerator.
- 164 remaining hits that read the shared window's own document: Find, editing, `canSave`,
  export, prompts, and document switching in about 30 `AppState` extensions, plus 14 view reads
  and the forwarder and construction code.

Meeting the literal gate in B2 would mean either moving that window-scoped logic onto
`WindowState` or renaming the property only to satisfy the grep. Moving the logic is PR C's
per-window restructure, done without C's routing, and the rename proves nothing. The owner
chose this reading:
- B2's gate is that `sessionCache` is registry-only, and that no `currentDocument` hit
  outside `WindowState` builds or checks an inventory. The PR classifies each remaining hit as
  "window-scoped; C retargets".
- The zero-hit form moves to C, as W2's last bullet. C's §10 row now names it.

Rejected: the literal reading (B).

**Open for later PRs.** The Save Copy owner walk fails closed on a candidate with no binding or
proof. Every window's document is a candidate, as the shared window's always was. So an untitled,
record-less document in another window refuses every Save Copy and export. This can't happen
with one window: Save Copy and export run only from a file-backed document. A second window
can't exist before PR C, and PR D2 owns that window's filter.
`testAnUntitledRecordlessDocumentInASecondWindowFailsSaveCopyClosed` pins this behavior.

Evidence: `WindowStateRegistryAppTests`.
- Fifteen named tests connect a second `WindowState`, show it a session no cache, retirement,
  binding, or recovery holds, and require each operation to see it. Each test then hides the
  session as a control.
- Making the enumerator see only the first window fails 14 of them; the fifteenth is itself a
  control.
- The I2 grep finds `sessionCache` only in the registry. Each remaining `currentDocument` hit is
  classified in the PR body.

Alternatives: keep the per-site lists and append each window's document (rejected: the next
inventory added would miss windows again, and I2 asks for one enumerator); a registry that owns
the windows' documents (rejected: a window owns its document, and the registry only asks it
which one it shows); dropping untitled, record-less window documents from the Save Copy walk
now (rejected for B2: it weakens a fail-closed ownership check without a second window to test
it against); moving the window-scoped reads onto `WindowState`, or renaming them, to meet the
literal I2 gate in B2 (rejected by the owner; see "How B2 reads I2" above).
