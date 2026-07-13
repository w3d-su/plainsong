# WorkspaceKit filesystem authority contract

> **Status:** implemented as a Phase 3 WS3B WorkspaceKit foundation plus transactional App
> reload capture/install and authority-bound reload auto-open. Workspace-search-result
> activation through retained `WorkspaceSearchFileAuthority`, EditorKit ownership, sidebar/UI
> work, workspace item rename/move/Trash, and session relocation remain follow-ups.

## Authority

`WorkspaceFileSystemRootAuthority` is established before an operation begins. It captures:

- one canonical root spelling and its physical `(device, inode)` identity;
- the original URL only for display/security-scope access; and
- a `WorkspaceFileSystemLocation` containing a normalized lexical root-relative path.

The relative path rejects empty, absolute, parent-traversing, and embedded-NUL input. A URL
computed from the original spelling is never filesystem authority.

Capture starts under the selected root's security-scoped lease, opens that directory exactly
once, samples `(device, inode)` from the opened descriptor, and derives its canonical spelling
from that same descriptor. A no-follow open of the derived spelling must resolve to the same
identity and spelling before capture succeeds. The original descriptor is retained by a
reference-backed `Sendable` lifetime token so moves or symlink retargets cannot redirect the
authority; construction throws on disagreement instead of storing a partial identity. Value
equality and hashing use the stable canonical spelling and physical identity, never the
descriptor integer. Async capture checks cancellation before starting, after the child task
constructs an authority, and before returning; a successfully constructed authority is released
(via deinit) when cancellation wins. Post-capture revalidation of the canonical root spelling
normalizes missing, symlink, unreadable, or replaced roots to `namespaceChanged` rather than
leaking leaf-level errors.

Each operation opens `/`, walks every canonical-root component, then walks every relative
parent component with `openat(..., O_DIRECTORY | O_NOFOLLOW)`. It retains that complete
descriptor chain until the operation ends. Every descriptor identity must still match both
its original `fstat` result and the no-follow directory entry under its retained parent.
The anchored layer never follows symlinks. A caller may resolve and containment-check an
allowed alias before constructing a location, but the resulting canonical root-relative path
is the only path the operation retains; any later symlink substitution fails closed.

The chain is validated before opening a leaf and again at operation-specific commit,
durability, rollback, and postflight boundaries. The terminal chain–leaf–chain validation is
repeated after the postflight test hook, so a mutation at the last instrumented boundary is
also rejected before an outcome is returned. Moving,
replacing, exchanging, or changing
the root, any ancestor, or the final parent invalidates the authority with
`namespaceChanged`. Opening `root/nested`, moving it to `root/moved`, recreating
`root/nested`, and continuing through the old descriptor is therefore rejected.

## Coherent reads

Reads open the final leaf once with `O_NOFOLLOW`, require a regular file, and sample metadata
from that descriptor before and after reading. Before returning bytes, the reader validates:

1. the retained root/ancestor/final-parent chain;
2. the final leaf name against the exact descriptor identity;
3. that same retained chain again; and
4. byte count and metadata stability for that descriptor.

`namespaceChanged` is fail-closed and is not retried. Content instability may be retried
within the bounded coherent reader. Cancellation is returned as `cancelled`. No successful
outcome may contain bytes from a descriptor detached from the captured namespace.

Production workspace search first canonicalizes an initially present, in-root alias under its
existing physical-target policy through the request's one captured authority, then builds the
canonical location from that same request-owned root. Candidate planning, ignore files,
overlays, reads, security-scoped access, and result authority cannot supply an independent root
URL. App workspace reload captures the snapshot and root authority together off the main actor
and proves that the selected root spelling still names the captured physical identity. When
reload auto-open is requested, selected-node location, anchored file loading, and cache/session
validation are derived end-to-end from `capture.rootAuthority`; no activation step resolves the
mutable selected root URL again. All throwing activation preparation finishes before the
snapshot, authority, installed generation, tree, and prepared session are committed without a
main-actor suspension. A post-proof root replacement or failed/mismatched activation publishes
none of capture A, so snapshot/authority A cannot be installed beside a session loaded from B.
The installed capture generation must equal the current workspace generation before search may
use the pair, so a reload that has advanced generation cannot label an old snapshot/authority
as the new generation while the replacement scan is suspended. Main-actor request construction
is pure. Disk results and eligible overlays carry `WorkspaceSearchFileAuthority`: the location
plus identity sampled from the exact read/validation descriptor. Workspace-search-result
activation remains deferred and must consume that pair rather than derive fresh authority from
the result path; reload auto-open does not close that gate.

## Transactional writes

All writes first create a same-directory, exclusive `.plainsong-write-*.tmp` file as `0600`
through an `O_RDWR` descriptor. Preparation explicitly truncates to zero, writes the requested
byte count, `fsync`s, verifies descriptor size plus SHA-256 against the requested `Data`, applies
the existing destination mode when replacing, `fsync`s again, and repeats exact verification.
The expected byte count and digest stay in `PreparedWrite`; descriptor content and the temporary
name's identity are revalidated after preparation, immediately before rename, after rename,
and at the final durable postflight. Empty writes therefore commit as exact zero-byte files, and
a same-size or longer external mutation can never be reported as durable requested bytes.

For an existing destination, commit uses
`renameatx_np(RENAME_SWAP | RENAME_NOFOLLOW_ANY)`. The displaced entry remains rollback
material until the writer has validated both names, validated the entire chain, synced the
parent directory, and completed post-sync validation. Only then may it unlink the displaced
entry and sync that cleanup.

For a missing destination, commit uses
`renameatx_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)`. A racing creator is never overwritten.
The new leaf, complete chain, and parent-directory sync must all pass before the create is
durable.

Every post-rename failure, including `.afterRenameSwap`, reaches reverse-swap rollback only
after the temporary entry is proved to be the writer-owned original identity and the destination
is proved to be the prepared identity. An observed missing, replaced, or unrelated entry aborts
rollback without another destructive namespace operation and returns
`committedButIndeterminate`. A temporary name occupied by a racer is
`removalIndeterminate`, never `retained`. Rollback is revalidated and its parent directory is
synced before the writer may report that the write was not committed. Cancellation follows the
same rule and cannot turn a possibly visible commit into an ordinary failure.

Every destructive cleanup carries the writer-owned artifact identity. Cleanup may move the
current entry to a randomly named, same-directory `.plainsong-cleanup-*.tmp` staging name before
removal. That sibling name is ordinary and enumerable; it is not private and supplies no
isolation or ownership boundary. No cleanup path restores a mutable staging name into the
original destination after a separate identity check.

The macOS primitives used here are name-based. `renameatx_np` and `unlinkat` accept no expected
`(device, inode)` or source-descriptor operand, and macOS exposes no regular-file `funlinkat`.
Final-boundary test hooks therefore run after the last identity validation and immediately
before rollback swap, staging rename, or staging unlink. An injected mutation can fail closed
before the syscall, and every completed namespace mutation is revalidated afterward, but these
checks do not make production operations identity-conditional or atomically safe.

Residual name-based races remain between:

- final validation of the prepared and destination names and an existing-file `RENAME_SWAP`;
- final validation of the prepared source and a missing-file `RENAME_EXCL` commit
  (`RENAME_EXCL` protects destination absence, not source identity);
- final validation of the displaced original and committed destination and rollback
  `RENAME_SWAP`;
- final validation of an artifact and `RENAME_EXCL` into the cleanup staging name; and
- final validation of the cleanup staging name and `unlinkat`.

If validation or post-operation proof observes a mismatch, no further destructive operation is
attempted and the outcome is retained/indeterminate as appropriate. `.retained(location)` is
used only when the writer-owned identity is observed at that reported location; a missing,
mismatched, or racer-owned name is `.removalIndeterminate(location)`. `.none` requires a
completed unlink, directory sync, and post-validation at the tracked names, but it is not a
claim that the unlink syscall itself had an unavailable expected-identity condition.

After commit durability, cleanup classification, and final postflight, durable writes resample
the complete metadata from the still-open committed descriptor and prove the destination name
still references it. The returned identity, byte count, modification time, and change time are
therefore final destination metadata, not the pre-rename sample.

## Outcome model

`WorkspaceFileWriteOutcome` forces callers to handle three states:

| Outcome | Proven state | Caller action |
|---|---|---|
| `notCommitted` | New bytes are proven absent from the destination namespace. | Preserve the current document; inspect `artifactState` for temporary cleanup. |
| `committedAndDurable` | New destination bytes and the commit directory entry are durable. | Adopt returned metadata; process any retained or removal-indeterminate cleanup artifact. |
| `committedButIndeterminate` | New bytes may be visible, or rollback durability/namespace continuity could not be proven. | Stop blind retries and reconcile using destination state, `preparedMetadata`, and any recovery artifact. |

Artifact state is independently typed as `none`, `retained(location)`, or
`removalIndeterminate(location)`. A namespace-change outcome does not authorize resolving the
same mutable URL again; reconciliation must first establish fresh authority.

`MarkdownFileStore.save(text:at:expecting:)` returns this outcome unchanged. Its legacy URL
save maps durable success normally, maps proven non-commit to `unwritable`, and surfaces
indeterminate commit state as `writeRequiresReconciliation` rather than claiming failure.
That synchronous compatibility facade finishes its transaction even when it inherits a
cancelled scheduling task; the typed location API continues to honor cancellation and expose
its exact outcome.

## Deterministic regression boundary

WorkspaceKit tests use synchronous event hooks and injected syscall-boundary failures—never
timing sleeps—to cover:

- symlink, intermediate, root, final-parent, and leaf substitution;
- existing and missing coherent reads;
- swap replacement, exclusive create, and exclusive-create collision;
- failure after swap/exclusive rename, displaced-entry capture, postcommit leaf validation,
  parent-directory sync, postflight namespace replacement, rollback, cleanup unlink, and
  cleanup sync;
- root symlink retarget/move/replacement at every authority-capture phase;
- longer, same-size, pre-rename, and post-rename prepared-byte mutation plus exact empty writes;
- selected-root replacement after proof but before reload auto-open, proving capture A is not
  installed alongside activation from B;
- a displaced-name racer combined with `.afterRenameSwap` failure, proving no reverse swap and
  a truthful `removalIndeterminate` recovery state;
- racing replacement names at temporary, rollback-artifact, cleanup-staging rename,
  final-validation-to-rollback-swap, final-validation-to-cleanup-unlink, unexpected displaced
  entry after swap, and created-destination cleanup boundaries;
- async authority capture cancellation that releases a live descriptor-backed authority;
- post-capture root moved/symlink-replaced/directory-replaced normalized to `namespaceChanged`;
- complete returned-metadata equality for existing replacement and missing creation;
- mismatched request roots and A/B root, ignore-rule, overlay, and result separation;
- durable rollback versus typed indeterminate rollback;
- cancellation and temporary-artifact cleanup; and
- canonical bytes, moved/replacement bytes, destination identities, outside sentinels, and
  absent or intentionally retained artifacts for every adversarial path.

The focused suites live in `WorkspaceAnchoredFileSystemTests`,
`WorkspaceNamespaceAuthorityTests`, `WorkspaceCoherentFileReaderTests`, and the
`WorkspaceFileWrite*Tests` files.
