# Stage single-file saves in the item-replacement directory when the parent refuses a sibling

Reproduced in a re-signed sandboxed dev build (document handed over by
LaunchServices, the same file-only extension the Open panel issues): "Autosave
Failed", and `prepareTemporaryWrite`'s `openat(parent,
".plainsong-write-<UUID>.tmp", O_CREAT|O_EXCL)` returned `EPERM`. A sandboxed
probe under the same grant measured: parent `O_RDONLY` EPERM, `O_SEARCH` ok,
sibling create EPERM, renaming the leaf within its parent EPERM, `fsync` of the
search-only parent ok, `url(for: .itemReplacementDirectory, appropriateFor:)` →
`<container>/tmp/TemporaryItems/NSIRD_*` on the same device, create/write/fsync
there ok, and `renameatx_np(RENAME_SWAP)` between that directory and the
granted leaf ok in both directions. The write now tries sibling staging first
(folder-grant saves are unchanged) and, only when the sibling create fails with
`EPERM`/`EACCES` before anything exists, captures Foundation's item-replacement
directory as its own root authority (refused if it is the destination parent or
on another device), anchors a descriptor chain to it, and runs the unchanged
transaction with every staged-name operation (prepare, displaced-entry capture,
rollback swap, quarantine/unlink cleanup, retained-artifact reporting) against
that directory and every destination operation against the parent; namespace
checks around the swap validate both chains. The emptied staging directory is
removed by identity-checked `rmdir`; one holding a reported artifact is kept.
Regressions inject the refused sibling (`createSiblingTemporary`) and stage in
a real separate directory (durable save with mode preservation, Foundation
default, rollback across directories, retained artifact location, exclusive
create, parent-returned-as-staging refusal, unavailable directory), plus a
POSIX `0500` parent where the fallback runs and the swap is then denied
cleanly. `Scripts/check-single-file-save-sandbox.sh` (run by `make
test-packages`) saves twice in a signed sandboxed probe under a LaunchServices
file-only grant after proving the grant refuses sibling creation; it fails on
the previous code with `notCommitted(.unreadable)`.

Alternatives: `FileManager.replaceItemAt` (works under the grant, but drops the
descriptor-anchored identity/expected-content checks and the writer-owned
rollback); `NSFileCoordinator` safe save (adds coordination, not permission to
write the parent); an in-place truncate-and-write of the granted file (no
atomicity: a crash or full disk mid-write leaves a torn document); asking for a
folder grant (changes the single-file workflow).

Supersedes: the single-file save limitation in the archive row 2026-10-18, Allow search-only directory authorities for single-file opens.
