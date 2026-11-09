# Save keeps the replaced file's metadata; new files follow the umask

**Finding.** A save publishes a prepared inode with `RENAME_SWAP` and unlinks the displaced
one. Only the `rwx` bits were copied (2026-10-01 row), so the first save or autosave silently
dropped the file's extended attributes (Finder tags and colors, `kMDItemWhereFroms`,
quarantine), its extended ACL and its creation date. New files kept the `0600` staging mode
for good: New File (`WorkspaceAnchoredItemCreation`) and any save to a missing destination
(Save As, Save Copy to a new name) published `0600`, while Export and image assets already
used `0666 & ~umask` and `0644`.

**Decision.**

- Before the swap, a replacing write copies the original's extended attributes, extended
  ACL (`acl_get_fd_np`/`acl_set_fd_np`) and creation date (`fgetattrlist`/`fsetattrlist`)
  onto the prepared file, right after the `fchmod` and before the second `fsync` and exact
  verification, so the prepared metadata the transaction later compares already includes
  them. The copy is best effort: the bytes are what Save promises, and the shipped sandbox
  or the volume may refuse an attribute. `com.apple.macl`, `com.apple.provenance`,
  `com.apple.decmpfs` and the `com.apple.system.` namespace are system-owned per inode and
  are never copied.
- A missing destination's staging file is created `0666`, letting the kernel apply the
  umask; New File does the same. A replacement's staging file stays `0600` until it receives
  the original's bits, so it is never briefly more permissive than the original.

**Not changed.**

- Hard links. No rename-based publication can keep them, and in-place writes would give up
  the `RENAME_SWAP` rollback material and displaced-entry proof this transaction relies on.
- `F_FULLFSYNC`. `committedAndDurable` stays defined at the syscall boundary, as the
  filesystem contract already says; the enum case's doc comment now states it too. A full
  flush costs milliseconds to tens of milliseconds per call on Apple SSDs, and autosave
  writes about once a second while typing; switching would be its own decision with a
  measurement.

**Tests.** `WorkspaceFileWriteMetadataPreservationTests`: Finder tags (also read back through
`URLResourceValues.tagNames`), a custom and an empty attribute, the creation date and an
`everyone allow` ACL survive a save that is proven to publish a new inode; a save to a
missing destination publishes `0666 & ~umask`; the system-owned attribute names are skipped.
`testCreatedFileModeFollowsTheUmask` covers New File. `ExactContentTests` still sees the
replacement staging file at `0600`. `Scripts/check-single-file-save-sandbox.sh` now also sets
an extended attribute on the probe document and requires it after two sandboxed saves
through the item-replacement directory; on `main` before this change that check fails.

**Alternatives rejected.** `fcopyfile(COPYFILE_XATTR | COPYFILE_ACL)`: one call, but it
copies the system-owned attributes too and gives no per-attribute control over a refusal.
Reading the umask with `umask(2)`: it changes the process-wide mask, so a concurrent create
could see the temporary value; passing `0666` to `openat` lets the kernel apply it.
