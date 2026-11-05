# Refuse saves on volumes without atomic rename before staging, and give write failures typed reasons

Saving a document on an exFAT disk always failed. The save writer replaces a file with
`renameatx_np(RENAME_SWAP)` and creates one with `RENAME_EXCL`. It reported every other
`errno` from those renames, and from the temporary file's create, truncate, write, `fsync` and
`fchmod`, as `unreadable` (or `durabilityFailed` for `fsync`). The App therefore showed the same
"Could not save changes" for an unsupported disk, a full disk, a read-only disk, and revoked
permission.

Measured on macOS 27.0 (26A428) with 64 MB disk images, in a directory below the volume root:

| Format | Advertised swap / exclusive rename | `RENAME_SWAP` over a file | `RENAME_EXCL` to a new name | Empty file's `st_ino` after its first write | Production writer before this change |
|---|---|---|---|---|---|
| exFAT (FSKit) | no / no | `ENOTSUP` | `ENOTSUP` | changes | replace and create: `notCommitted(changedIdentity, removalIndeterminate)`, one `.plainsong-write-*.tmp` left per attempt |
| MS-DOS (FAT32) | no / no | returns 0, but replaces the leaf like a plain rename; the original is gone | works | changes | same as exFAT |
| Mac OS Extended | not valid / yes | `ENOTSUP` | works | stable | replace: `notCommitted(unreadable, none)`; create: durable |
| APFS | yes / yes | works | works | stable | durable |

On exFAT and FAT32 the writer never reached the rename. The volume renumbers an empty file when
its first cluster is written, so the writer's identity check on its own temporary file failed with
`changedIdentity`. Cleanup could not prove the artifact's identity either, so every save and
autosave left a temporary file beside the document and reported it as a recovery artifact whose
removal could not be confirmed. `changedIdentity` also made the App start external-change handling
for a file that had not changed.

The writer now reads the destination volume with `fstatfs` and
`fgetattrlist(ATTR_VOL_CAPABILITIES)` through the retained parent descriptor. It does this after
the target expectation and before anything is staged. It refuses a read-only mount
(`readOnlyVolume`) and a volume without `RENAME_EXCL` (`unsupportedVolume`), because every write
publishes or cleans up with it. A replacement also needs `RENAME_SWAP`. A volume whose capabilities
cannot be read is refused as `unsupportedVolume`, as Export does. The advertised bits decide, not a
rename's result: FAT32 reports success for a swap it did not perform. After the check, the
temporary file's create, truncate, write, `fsync` and `fchmod` and both commit renames classify
`errno`. `ENOTSUP` becomes `unsupportedVolume`, `ENOSPC` and `EDQUOT` become `insufficientSpace`,
`EROFS` becomes `readOnlyVolume`, and `EPERM` and `EACCES` become `writeNotPermitted`. Any other
code keeps its earlier reason. The sibling create's `EPERM` or `EACCES` still selects separate
staging first. Directory `fsync`, rollback and cleanup keep their reasons, and item creation,
rename and Trash map the new cases to their existing `unreadable` failure.
`MarkdownFileStoreError` has one case per new reason, each with a cause and a next step; for an
unsupported disk the next step is to copy the file to a folder on the Mac or to an APFS disk. A
not-committed message that reports a recovery artifact now names the cause too.

After the change, the same images give `notCommitted(unsupportedVolume, none)` with nothing left
in the folder for both replace and create on exFAT and FAT32. Mac OS Extended refuses a
replacement the same way and still creates a new file durably. APFS is durable for both. An APFS
image mounted read-only gives `notCommitted(readOnlyVolume, none)`, and
`Scripts/check-single-file-save-sandbox.sh` still passes under a file-only grant. SMB and NFS were
not measured. A share that does not advertise the renames a save needs is now refused before
staging.

Alternatives:

- Map `errno` without the capability check. exFAT and FAT32 would still fail at the identity check
  and leave temporary files, and FAT32's swap would still destroy the rollback material.
- Read Foundation's `volumeSupportsSwapRenamingKey` and `volumeSupportsExclusiveRenamingKey`, as
  Export does. That lookup is path-based, but the writer already holds the parent descriptor, and
  a file-only grant may only search the parent.
- Write these volumes some other way:
  - A plain `rename` over the original keeps no rollback material, cannot re-check
    `existingContent` against the displaced file, and can overwrite a racing creator.
  - An in-place truncate-and-write was rejected in
    `2026-10-18-single-file-save-item-replacement.md`, because a crash or a full disk tears the
    document. exFAT also renumbers a file that is truncated to zero and rewritten.
  - `FileManager.replaceItemAt` drops the descriptor-anchored checks.

  Each of these relaxes the outcome contract in `docs/workspace-filesystem-contract.md`. On exFAT
  and FAT32 the `(device, inode)` identity that the App binds a session to also changes when a file
  is first written. A fallback writer therefore needs its own decision. So does a Save Copy… command
  that would let a refused session move to a supported folder.
