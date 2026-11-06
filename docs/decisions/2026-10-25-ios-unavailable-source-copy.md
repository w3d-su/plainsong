# Export retained unavailable source with an independent destination

Date: 2026-10-25. Integration-owner correction for review H3 (#217/#218).

Unavailable documents offer Save a Copy through the same production coordinator
as conflicts. It captures the retained session, exact source/revision, dirty flag,
binding, editor generation and typed unavailable reason. The origin grant may
already be revoked; it is compared only to fence changes, never reacquired or
used to authorize I/O. The existing store copies its in-memory source through a
new explicit directory grant, retained lease and create-new-leaf operation.

A later source/state/binding/generation/revocation change rejects the attempt,
including provider drain after creation. Copy never saves/overwrites/rebases the
original, clears dirty/conflict/unavailable, discards Undo or closes its writer.
The editor's revocation generation is not reduced by a later old-store snapshot.
Temporary copy destinations use the injected no-recents opener from #211.

The user can preserve text in this session even when Choose Again cannot safely
close a dirty unavailable writer. After successful copy the original remains
retained: the notice explicitly directs a restart and opening the saved copy to
continue. Copy acknowledgement does not authorize retiring the origin or bypassing
safe-close admission. This boundary is deliberate; an automatic second writer or
pretend-clean rebase was rejected. Existing recovery records remain intact.

Tests include real UIDocument/native Undo/readback after origin revocation,
controlled revocation before capture and during destination open/provider create,
exact state changes, lease retention until drain, and unchanged original source,
bytes, dirty state and admission. Normal conflict success now explains that Reload
replaces the editor with the disk version; the owner device gate must separately
exercise Reload during real Zhuyin marked text and subsequent native Undo/Redo.
Simulator composition tests do not close that physical-input gate.
