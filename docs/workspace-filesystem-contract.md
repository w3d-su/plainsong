# WorkspaceKit filesystem authority contract

> **Status:** implemented as a Phase 3 WS3B WorkspaceKit foundation plus transactional App
> reload capture/install, authority-bound reload and workspace-search activation, file-tree
> opening, completion metadata, and session writes. Visible Files/Search sidebar UI,
> workspace item rename/move/Trash, and session relocation remain follow-ups.

## Authority

`WorkspaceFileSystemRootAuthority` is established before an operation begins. It captures:

- one canonical root spelling and its physical `(device, inode)` identity;
- the original root spelling for display/security-scope access and exact URL-to-relative-path
  mapping; and
- a `WorkspaceFileSystemLocation` containing a normalized lexical root-relative path.

The relative path rejects empty, absolute, parent-traversing, and embedded-NUL input. A URL
computed from the original spelling is never filesystem authority. If a file URL has exact-byte
prefix matches against both canonical and original root spellings, `relativePath(forFileURL:)`
chooses the longest component prefix. Thus an original symlink nested beneath the canonical root
does not survive as a false leading relative component and fail the later no-follow traversal.

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
URL. Normalized candidate deduplication, dirty-overlay storage/lookup, ignore-file ancestor
enumeration, and deterministic path ordering use UTF-8 byte keys; canonically equivalent NFC/NFD
spellings remain independent paths and can neither suppress nor borrow one another's overlay.
The file tree uses the same byte identity for parent grouping and default-filter ancestors. When
the scanner cannot supply a resource identity, a namespaced ASCII hex encoding of the relative
path bytes supplies the fallback node ID rather than a canonically equivalent Swift `String` key.
App workspace reload captures the snapshot and root authority together off the main actor
and proves that the selected root spelling still names the captured physical identity. When
reload activation is requested, selected-node location and the exact file bytes, descriptor
metadata, identity, and SHA-256 digest are loaded through `capture.rootAuthority`; no activation
step resolves the mutable selected root URL again. A cache hit is not an early return: the
existing current or warm session is reconciled from that loaded activation file, and the
location/identity/digest become its retained anchored binding.

Because the activation load may suspend, reload proves the selected root spelling a second time
after that load, immediately before an uninterrupted main-actor commit of the prepared session,
snapshot, authority, installed generation, and tree. A failed proof or activation publishes none
of capture A, so capture A cannot be installed beside bytes loaded from B. If the current session
or its retained state location changes during that suspension, the reload is cancelled instead of
overriding the newer selection or applying a stale missing-file disposition. Cache and retired-
binding arbitration is repeated after the final proof and then committed without another
suspension, so an evicted cached source is not resurrected and a changed retirement cannot reach a
commit precondition. A cached or retired session is reusable only when any retained anchored
binding or exact re-homed quarantine location equals the prepared activation location; a URL-only
match across physical root A and replacement root B rejects the activation before mutating the
session or its binding. The installed capture generation must equal the current workspace
generation before search may use the pair, so a
reload that has advanced generation cannot label an old snapshot/authority as the new generation
while the replacement scan is suspended. Dirty overlay construction also requires an anchored
dirty session's retained root authority to equal the request's installed authority; a cached
dirty session bound to moved root A is excluded when the same selected spelling has become
replacement root B.

That last proof is a fail-closed publication boundary, not an identity-atomic namespace lock. An
external process can still move or replace a name after it. Installed consumers therefore retain
the authority and exact location instead of reopening a post-install URL: file-tree/sidebar open,
completion sibling reads, external-change reconciliation, and session save all stay on that
binding and reject later namespace disagreement. A re-homed missing-destination quarantine retains
its exact location as session authority even though no readable destination binding exists. If
the current session binding or quarantine belongs to an older authority and its exact location
lexically collides inside the installed replacement root, reload rejects that cross-authority
disposition. An outgoing retained session whose exact location is outside the newly selected root
is unrelated, so an ordinary workspace A-to-unrelated-workspace B switch may select B's first
editable file without weakening same-spelling replacement rejection. Completion falls back to
current-document metadata only across either authority mismatch, performing no workspace sibling
reads. There is no mutable-URL external-change handler installed after reload. Main-actor
search-request construction is pure. Disk results and
eligible overlays carry `WorkspaceSearchFileAuthority`: the location plus identity sampled from
the exact read/validation descriptor. Workspace-search-result activation consumes that retained
location and exact identity, and its post-activation check compares the installed session
binding's location to the accepted target; it never resolves the result URL to decide what was
installed.

## Transactional writes

All writes first create a same-directory, exclusive `.plainsong-write-*.tmp` file as `0600`
through an `O_RDWR` descriptor. Preparation explicitly truncates to zero, writes the requested
byte count, `fsync`s, verifies descriptor size plus SHA-256 against the requested `Data`, applies
the existing destination mode when replacing, `fsync`s again, and repeats exact verification.
The expected byte count and digest stay in `PreparedWrite`; descriptor content and the temporary
name's identity are revalidated after preparation, immediately before rename, after rename,
and at the final durable postflight. Empty writes therefore commit as exact zero-byte files, and
a same-size or longer external mutation can never be reported as durable requested bytes.

Here durability is defined at the host syscall boundary. `committedAndDurable` means the prepared
file `fsync`, the parent-directory `fsync` required to publish the destination, and the associated
namespace and metadata validations all succeeded. Cleanup durability uncertainty remains visible
in `cleanupState`; it does not erase an otherwise proven destination commit. The writer does not
issue `F_FULLFSYNC`, and this outcome is not a claim that physical media will preserve the bytes
across sudden power loss.

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
original destination after a separate identity check. Cleanup binds the artifact through an
already-open writer descriptor when one is available; otherwise identity inspection opens it
with `O_EVTONLY | O_NOFOLLOW`, not `O_RDONLY`, so write-only or no-access destination modes do not
turn a proven rollback into a false cleanup failure.

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
used only when the writer-owned identity is observed at that reported location. Before a
completed, synced removal, a missing, mismatched, racer-owned, or uninspectable tracked name is
`.removalIndeterminate(location)` because the writer cannot prove where its artifact went.
Cleanup observation is tri-state (`matchesExpected`, `missingOrDifferent`, or
`inspectionFailed`) and is accepted only between successful namespace proofs. `.none` is
returned only after completed unlink and directory sync plus tri-state observation that the
expected identity is absent from every tracked name under that namespace; an inspection error
can never collapse to `.none`. This is not a claim that the unlink syscall itself had an
unavailable expected-identity condition.

Every path that performs cleanup and then considers `notCommitted` re-proves the terminal
destination state and its retained namespace after cleanup: an existing write must still name
the exact original descriptor identity, while a missing write must still be absent. Failure or
uncertainty in that proof becomes `committedButIndeterminate`, with prepared metadata when the
still-open prepared descriptor can prove it and with a recovery-artifact state that truthfully
reports where the prepared identity is retained or where removal is indeterminate.

After commit durability, cleanup classification, and final postflight, durable writes resample
the complete metadata from the still-open committed descriptor and prove the destination name
still references it. The returned identity, byte count, modification time, and change time are
therefore final destination metadata, not the pre-rename sample.

## Outcome model

`WorkspaceFileWriteOutcome` forces callers to handle three states:

| Outcome | Proven state | Caller action |
|---|---|---|
| `notCommitted` | New bytes are proven absent from the destination namespace. | Preserve the current document; inspect `artifactState` for temporary cleanup. |
| `committedAndDurable` | Requested bytes, prepared-file and destination-directory `fsync`, and host-side validations completed; cleanup uncertainty remains typed separately. This is not `F_FULLFSYNC` or a sudden-power physical-media guarantee. | Adopt returned metadata; process any retained or removal-indeterminate cleanup artifact. |
| `committedButIndeterminate` | New bytes may be visible, or rollback durability/namespace continuity could not be proven. | Stop blind retries and reconcile using destination state, `preparedMetadata`, and any recovery artifact. |

Artifact state is independently typed as `none`, `retained(location)`, or
`removalIndeterminate(location)`. A namespace-change outcome does not authorize resolving the
same mutable URL again; reconciliation must first establish fresh authority.

`MarkdownFileStore.save(text:at:expecting:)` returns this outcome unchanged. Its legacy URL
save returns normally only for durable success with no cleanup artifact. Durable success with a
retained or removal-indeterminate artifact throws `committedWithCleanupRequired`, explicitly
stating that the destination committed; proven non-commit maps to `unwritable` only when no
artifact remains, otherwise `writeNotCommittedWithCleanupRequired` preserves the exact typed
artifact. Indeterminate commit state remains `writeRequiresReconciliation` rather than claiming
failure.
That synchronous compatibility facade finishes its transaction even when it inherits a
cancelled scheduling task; the typed location API continues to honor cancellation and expose
its exact outcome.

App workspace sessions retain a descriptor-bound location, exact loaded identity, and exact-byte
digest whether the session was loaded through an installed workspace authority or first became
managed as a standalone session. The standalone proof also captures its location under the
then-installed workspace authority when that membership exists. Ordinary Cmd-S/autosave writes
through that retained location with the typed `existingContent(identity, sha256Digest:)`
expectation; it never reopens `session.fileURL` to widen or reconstruct proof. Missing, deleted,
replaced, or unavailable proof fails closed. Save Copy for a destination inside or outside the
installed workspace establishes one no-follow location. Before
entering the writer it inspects the target once from the retained parent descriptor, derives the
actual parent/leaf spelling and physical identity without requiring content-read permission, and
uses only `.existing(identity)` or `.missing`; it never widens the first attempt to
`existingOrMissing`. A noncanonical request spelling is rejected so App state cannot split from the
scanner's key. Ownership arbitration deduplicates current, cached, retired, and editor-bound
sessions, then protects exact/canonically equivalent locations, indeterminate-write contexts, and
matching destination identities. When an unanchored session first becomes App-managed, App retains
its descriptor-derived location and identity. Arbitration never re-derives that proof from mutable
`session.fileURL`; missing proof, deletion, replacement, or inspection failure fails closed. The
source self-collision exception applies only when the destination is proven missing and the
source's retained authority/location equals the destination exactly. Exact spelling comparisons
use literal UTF-8 bytes rather than Swift's canonically equivalent `String ==`. Ownership still
rejects the same or canonically equivalent App-visible path across different root authorities for
current, cached, retired, editor-bound, and quarantined sessions. Case variants collide only when
the destination parent reports case-insensitive names; distinct case spellings remain valid on
case-sensitive volumes. Existing aliases and hard links always collide.

`WorkspaceFileSystemLocation.fileURL` is derived lexically from the captured canonical root URL
and stored relative-path bytes. Construction does not inspect the leaf, and the resulting spelling
never gains a directory slash when that leaf is already or later becomes a directory. Location
equality/hashing also consumes the literal relative-path bytes, so NFC and NFD spellings remain
distinct and equal locations always expose identical slash-free URLs. App binding, quarantine,
autosave, and context lookup begins from retained session identity and uses that stored URL
spelling without standardizing or resolving the mutable session URL. The App clears only the
source session's old state after durable Save Copy success.

Root capture, `relativePath(forFileURL:)`, standalone capture/recovery, and LRU keys preserve
literal UTF-8 bytes rather than making an NFC-to-NFD `standardizedFileURL` round trip. Raw
non-file URLs and NUL-bearing paths are rejected before C-string descriptor calls; traversal and
containment checks remain descriptor-bound. A descriptor-derived canonical parent may give aliases
one cache key without changing the literal leaf bytes, so an NFC missing source can reuse its exact
retained authority/location while an NFD alternative is not an exact recovery target. If the
canonical and original root spellings both exactly prefix a supplied file URL, the longest
component prefix wins so nested original symlinks round-trip to the intended relative spelling.

On an external notification, App takes one coherent read through the retained anchored binding or
standalone proof and compares literal location, descriptor identity, and SHA-256 before adopting
the observation. mtime/FNV, a mutable session URL, or cached/retired reuse never authorizes proof
replacement. A dirty session with any unaccepted identity or content change, including a same-inode
rewrite, enters conflict handling, cancels autosave, and retains the old proof until explicit
Reload or Keep Mine obtains and adopts a fresh observation. Cmd-S/autosave therefore cannot
overwrite those external bytes before resolution. Keep Mine accepts the newest fresh observation
(C even if the original prompt described B), clears matching detached and missing-file fences, and
restores save eligibility for both anchored and standalone delete/recreate sessions. If a clean
quarantined session's local source differs byte-for-byte from the observation, Keep Mine marks the
session and its LRU record dirty before autosave scheduling rather than exposing a false clean
state. A stateful retained A session (pending conflict,
detachment, or indeterminate context) blocks a replacement-parent B at the same lexical URL, so B
cannot inherit or clear A's URL-keyed fence merely by reusing the spelling.

Any session
`committedButIndeterminate`, including Save Copy, installs a per-session reconciliation quarantine
that retains the exact destination and prepared-byte digest. A readable Save Copy destination
records its observed identity/digest as pending and is presented through Reload or Keep Mine while
the prior proof remains intact; an observed-missing destination may be retried only with exclusive
`missing`, never `existingOrMissing`. A retry denoting that same quarantined destination always reuses the
retained location, even if the workspace is closed or replacement root B is now installed at the
same spelling, so namespace validation remains bound to A. While that quarantine exists, any
different destination spelling requires reconciliation before another Save Copy: case or Unicode
variants and an outside-workspace symlink can otherwise alias the uncertain entry on macOS and
bypass the anchored expectation through the legacy URL writer. Once a missing destination has
been re-homed, its exact quarantine URL is also the session-state key; cleanup never resolves a
later symlink at that name and therefore cannot clear another session's state. A symlink,
non-regular leaf, unreadable file, or inspection failure stays quarantined and exposes Check Again;
it does not authorize any writer. Check Again reclassifies only the retained location and authority,
eventually yielding Reload/Keep Mine, the exact missing recovery, or the same actionable blocked
state. Quarantine is a retention condition independent of `isDirty`: LRU eviction, editor
retirement and metadata cleanup, missing-file close, workspace close, and workspace switch may not
discard even a clean quarantined session or its exact context before reconciliation. Blind Cmd-S
and autosave remain blocked until explicit reconciliation or a durable exact missing recovery
clears the quarantine. Workspace retirement decides security-scope transfer only from the retained
anchored authority or the standalone proof's captured installed-workspace membership; it never
reopens or reinspects the current path.

For ordinary save and Save Copy, App completes a proven durable state transition first—adopting
metadata, marking clean, or re-homing the session—then retains every non-`none` `cleanupState` as
an exact authority-backed artifact notice and presents “File Saved; Cleanup Required.” A
`notCommitted` result keeps the session dirty and likewise retains any non-`none` `artifactState`.
Artifacts are not auto-deleted because the public artifact state does not carry an expected
identity for a safe later unlink.

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
- cached-current activation reconciliation from the exact loaded file, including an exact-byte
  digest for UTF-8 BOM input, rather than trusting the pre-existing session or URL metadata;
- selected-root replacement both after the first proof and after activation load, proving capture
  A is not installed alongside activation from B, plus missing-current detachment with autosave
  suppressed;
- workspace-search activation postcheck and completion refresh after an A-to-B root-name
  replacement, plus a real anchored A-to-unrelated-B workspace switch, proving cached/retired
  activation never rebinds A by URL alone without blocking an unrelated destination and a current
  session still bound or quarantined to A gets current-document-only completion rather than
  sibling reads from B;
- dirty-overlay collection after root A is moved and replacement B takes its spelling, proving a
  cached session still bound to A cannot inject its dirty text into B's search request;
- synthetic NFC/NFD snapshot candidates, overlays, and nested ignore files, proving normalized
  paths remain distinct UTF-8 keys and no spelling suppresses or supplies another's overlay;
- NFC/NFD directory pairs in the file tree, proving grouping, default-filter ancestors, fallback
  IDs, and expansion state remain distinct even without resource identities;
- a nested original-root symlink that also lies below the canonical root, proving relative-path
  extraction selects the longest exact-byte prefix before no-follow validation;
- file-tree/sidebar activation, installed-workspace Save Copy, descriptor-canonical target
  inspection for `0200`/`000` leaves, cached/retired/editor ownership collision refusal,
  retained unanchored location/identity/loaded-digest proof after unlink, replacement, or same-inode
  content change, fail-closed unavailable proof, authority-exact original-path missing recovery,
  A-to-B same-spelling and cross-authority cached/retired/editor/context ownership refusal, literal
  NFC/NFD retry spelling, lexical URL stability when the leaf is already or later becomes a
  directory, stable `sessionStateURL`, distinct-case success on case-sensitive volumes, retained
  save authority after workspace close, and per-session indeterminate-write quarantine;
- final-suspension current-session changes and cached-source eviction, proving reload neither
  steals a newer selection nor commits a stale cached/retired activation;
- Save Copy indeterminate outcomes with readable, still-missing, symlink, non-regular, and
  unreadable destinations, proving Reload/Keep Mine, exact `.missing` recovery, and actionable
  Check Again quarantine respectively, plus differently spelled, replacement-root, case-variant,
  and outside-symlink retry refusal and replacement-symlink cleanup cases proving the retained
  context neither writes B nor clears another session's state;
- a displaced-name racer combined with `.afterRenameSwap` failure, proving no reverse swap and
  a truthful `removalIndeterminate` recovery state;
- racing replacement names at temporary, rollback-artifact, cleanup-staging rename,
  final-validation-to-rollback-swap, final-validation-to-cleanup-unlink, unexpected displaced
  entry after swap, and created-destination cleanup boundaries;
- prepared bytes published at the destination during temporary-preparation, precommit, existing
  rollback, and missing rollback cleanup, proving no such path can report `notCommitted` without
  a terminal destination-and-namespace proof;
- tri-state cleanup inspection failure plus write-only and no-access artifact modes, proving
  uncertainty cannot collapse to `.none` and cleanup does not require read permission;
- durable retained/removal-indeterminate and proven-noncommit artifact outcomes through typed and
  App saves, proving successful commits finish clean/re-home while exact cleanup notices remain
  observable and noncommits remain dirty;
- clean-session quarantine through LRU eviction, editor retirement/metadata cleanup, missing-file
  close, workspace close, and workspace switch, plus unlinked/replaced unanchored retirement,
  proving reconciliation context and captured membership outlive every lifecycle exit;
- anchored and standalone delete/recreate Keep Mine resolution, proving detached/missing fences
  clear and Cmd-S/autosave resume, plus a clean quarantine whose local and observed Unicode
  spellings are canonically equivalent but byte-distinct, proving the session/LRU becomes dirty;
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
