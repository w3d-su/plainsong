# WorkspaceKit filesystem authority contract

> **Status:** implemented as a Phase 3 WS3B WorkspaceKit foundation plus transactional App
> reload capture/install, authority-bound reload and workspace-search activation, file-tree
> opening, completion metadata, and session writes. Draft PR #84 adds workspace item
> rename/move/Trash and transactional session relocation on that retained-authority baseline.
> Validation is tracked against the exact PR tip; visible Files/Search sidebar expansion remains
> a follow-up.

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
atomically establishes C as the saved-text baseline without replacing or publishing the current
editor source. Returning the editor to exact C is therefore clean, while returning it to old A
remains dirty. A detached cached or reusable retired session reopened after switching to another
file is admitted through its retained authority checks and into this arbitration, so a recreated
leaf can present Reload/Keep Mine; activation itself neither clears the detached fence nor adopts C. Explicit
resolution is required even if the leaf was restored with A's exact identity, digest, and bytes,
because the missing-file transition invalidated the session's saved baseline and save fence. A
successful resolution restores save eligibility for both anchored and standalone delete/recreate
sessions. If a clean quarantined session's local source differs byte-for-byte from the observation,
Keep Mine marks the
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

## Workspace item creation

New files and folders use the retained directory node from the installed workspace snapshot, not a
URL containment check followed by `FileManager` creation. App passes that directory's exact
no-follow `(device, inode, directory)` expectation to WorkspaceKit and fences all concurrent
namespace mutation and image placement before the first filesystem call. If the selected directory
is unavailable or its snapshot expectation no longer matches, creation fails without falling back
to the workspace root. App also checks destination ownership independently of any source session:
a missing spelling retained by a current, cached, retired, detached, editor-bound, LRU, prompt,
observation, indeterminate-write, or operation/text-recovery owner cannot be recreated. Every
requested destination entry reserves its byte-component-bounded namespace subtree regardless of
whether that entry would be a file or directory: if recovery owns `archive/post.md`, neither create
nor relocation may publish an ordinary file named `archive`. Prefix-only siblings such as
`archive-copy/post.md` remain independent.

Before the first creating syscall, App durably records the logical destination, a
security-scoped bookmark for its exact parent plus the literal destination leaf, and one unique
root-level `.plainsong-create-<uuid>` staging location. A bookmark is accepted only after it
resolves to the expected no-follow parent identity. The staging name is therefore known across a
restart before it can contain an item, while the display URL remains diagnostics rather than
authority.

WorkspaceKit creates the new item only at that root staging leaf. Empty-file creation uses
`openat(O_CREAT | O_EXCL | O_NOFOLLOW_ANY)` relative to the retained root, captures the returned
descriptor identity, fsyncs the file, fsyncs the retained root directory, and revalidates the
exact entry. It creates no unjournaled writer temporary. `O_EXCL` preserves a racing creator and
`O_NOFOLLOW_ANY` rejects symlink traversal.

Darwin has no flag-bearing `mkdirat` equivalent. Folder creation therefore obtains a same-device
`.itemReplacementDirectory` while the workspace security scope is active, opens the exact
OS-created random entry, and proves its descriptor identity through two immediately adjacent
named-path validations. WorkspaceKit requires current-user ownership, exact mode `0700`, zero
flags, an empty directory, and an allowlist limited to `com.apple.macl`,
`com.apple.provenance`, and `com.apple.quarantine`. The first descriptor read may lazily
materialize system-managed xattr state and advance ctime, so that read is completed before choosing
the stable baseline. Readable allowed xattrs are retained as exact bytes; an allowed value that
returns `EPERM` or `EACCES` is retained as `accessControlled` and guarded by the exact name set
plus ctime stability rather than a false byte-value claim.

After the final named proof, WorkspaceKit removes the OS random name, proves that path missing,
and captures a post-removal ctime/xattr and kernel-reported-path baseline from the still-open
descriptor. Removal may legitimately advance ctime, so identity, ownership, mode, flags, and
xattrs must remain equal across that boundary before the new baseline is installed. A
process-lifetime per-device registry retains only the descriptor and its post-removal baseline;
it does not depend on reopening the temporary name.

WorkspaceKit then uses that exact descriptor as the source of an atomic `fclonefileat` into the
root staging path. Immediately before and after every clone,
the source must still satisfy its device, owner, mode, flags, emptiness, ctime/xattr, and
kernel-reported-path baseline.
`CLONE_NOFOLLOW_ANY | CLONE_NOOWNERCOPY` makes staging creation symlink-free and exclusive without
copying source ownership. Cross-device or non-clone-capable volumes fail closed. After the clone,
WorkspaceKit opens the exact staging directory, captures its stable empty-directory policy, fsyncs
it and the root, and repeatedly validates its descriptor/name and allowed xattrs.

Only after either staging artifact is durable does WorkspaceKit invoke the App callback. App
captures and resolves a second security-scoped bookmark for that exact item identity, then advances
the same journal from `planned` to `prepared` before returning. A callback or journal failure
aborts publication and leaves the root-relative staging artifact fenced. Once the callback returns,
WorkspaceKit publishes from the retained root staging parent and literal leaf to the complete
root-relative destination with `renameatx_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)`. The selected
destination parent expectation, destination absence, exact moved identity, both parent syncs, and
terminal namespace are revalidated. A collision is never overwritten and the staging artifact is
retained for recovery.

After durable publication, App resolves both bookmarks again. It advances `prepared` to
`committed` only when the retained destination-parent authority still maps the literal logical
destination, the item bookmark resolves to that exact destination identity, and the staging leaf
is proven missing. The committed record is durable before editor activation and is re-proven
before journal removal. `unknown`, `planned`, `prepared`, and `committed` are explicit persisted
phases; a legacy record with no phase is `unknown` and cannot be inferred from mutable paths.

macOS 14 and 15 expose no conditional `rmdir` by descriptor. A same-user swap between the final
temporary-name proof and `rmdir` can therefore cause an empty replacement at that OS random name
to be removed. Post-removal kernel-reported-path validation rejects an ordinarily moved original
descriptor, but cannot make a synchronized name swap identity-atomic. This residual never targets
a workspace name or editor data, and every later source validation still fails closed on a changed
reported path, policy, or contents.

Darwin has no directory equivalent of `openat(O_CREAT | O_EXCL)` that both creates the directory
and returns its descriptor, and rename remains name-based rather than expected-inode-conditional.
A same-user process can therefore replace a newly cloned staging directory before its first open,
or substitute the staging leaf after validation but before rename. WorkspaceKit never name-based
deletes or reverses such an entry: it records the actual moved identity when observable, while the
pre-publication item bookmark continues locating the expected identity. Likewise, if the
destination parent is replaced for the final root-relative rename and later leaves the workspace,
the item locator remains durable but App refuses to adopt or release it outside the jointly proven
logical destination. These cases stay actionable through Check Again or explicit Stop Tracking;
they cannot be collapsed into “staging missing.”

Creation reports one of three typed outcomes:

- `notCreated` proves the requested item did not commit;
- `createdAndDurable` returns the exact created location and no-follow identity that App may
  activate without reopening a mutable URL. For a folder, this is the exact published destination
  identity after the unavoidable staging clone-to-open interval, not a provenance claim
  that Darwin cannot supply; and
- `creationStateIndeterminate` retains the expected created identity when known and distinguishes
  a proven recovery location from an unknown location. It never labels a replacement directory as
  Plainsong's recovery artifact.

An indeterminate creation enters the same global recovery queue as rename, move, and Trash. Until
it is reconciled or explicitly released, all later workspace namespace mutations are blocked.
Before the first creating syscall, App persists a planned operation containing the destination
parent locator, literal leaf, and root staging path. After the staged identity is captured, the
same operation ID is durably advanced to prepared with its item locator before publication. A
restart that sees only the planned form may automatically release it only when both logical and
staging candidates are proven missing under the retained parent authorities. Any occupant,
identity uncertainty, unavailable locator, or inspection failure remains fail-closed for manual
reconciliation; it is never adopted or removed as Plainsong-owned material.

## Workspace item namespace mutations

Rename, move, and Trash begin from the installed workspace snapshot and its retained root
authority. A mutable node carries a no-follow expectation containing the selected entry's exact
`(device, inode, kind)`. App does not replace that expectation by inspecting the selected URL
again: a source that disappeared, changed kind, or now names a different identity is a stale
snapshot and must fail closed before the replacement can be adopted as the selected item.

User-entered names are single lexical components. Empty names, `.`, `..`, embedded `/`, and
embedded NUL are rejected before a filesystem call. A name whose whitespace-and-newline-trimmed
form is empty is also rejected, including space-only, tab-only, newline-only, or mixed-whitespace
spellings. That trim is validation-only: every accepted UTF-8 spelling, including leading or
trailing whitespace, is returned and published literally without rewriting its bytes. Names and
affected-session paths are compared as literal UTF-8 bytes. A directory affects itself plus a
descendant only when the retained relative path is byte-equal or begins with the source bytes
followed by `/`; canonically equivalent NFC/NFD spellings and prefix-only siblings remain
independent App-state keys.

Source and destination locations must belong to the same retained
`WorkspaceFileSystemRootAuthority`. The mutation layer anchors both parent chains with
descriptor-relative, no-follow traversal, validates the snapshot expectation and destination
absence, rejects moving a directory inside its own retained descendant, and publishes with an
exclusive `renameatx_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)` whose complete source and destination
paths are resolved from one retained root descriptor. The final syscall therefore cannot publish
through a child descriptor that another process moved outside the workspace after preflight. A
destination racer is never overwritten. On a filesystem that resolves a case-only or NFC/NFD-only
alternative spelling to the same source entry in the same physical parent, that one equivalent
entry is admitted as a spelling-only rename; postflight requires the requested literal directory
entry to exist and the old literal entry to be absent. No unrelated equivalent owner is admitted.
A selected symbolic link is treated as the lexical link entry; rename, move, and Trash never
resolve it to the target.

Namespace mutation has three semantic outcomes:

| Outcome | Proven state | Caller action |
|---|---|---|
| durable move | The expected entry is proven at the destination, the source transition and retained parent namespaces validate, and required directory syncs completed. | Commit the prepared App relocation. |
| not moved | The expected entry is proven not to have committed at the destination. | Preserve every App owner and old key unchanged. |
| indeterminate | A rename became visible, or its identity, namespace continuity, App preparation, or durability could not be proven. | Do not guess or partially rekey; stop blind retries and surface reconciliation/recovery state. |

Destination-dependent App preparation may run only while the relocated identity is proven at the
destination. Once the forward rename succeeds, a later preparation, postflight, or durability
failure is always indeterminate. WorkspaceKit does not attempt an automatic reverse rename: Darwin
cannot make that reverse operation conditional on the already captured inode, so a final-boundary
replacement could otherwise be moved into the source name.

Darwin's namespace primitives remain name-based. `renameatx_np` has no expected-inode or
source-descriptor operand, so validation immediately before a rename does not make the syscall
identity-conditional. WorkspaceKit therefore captures the actual destination entry immediately
after a successful exclusive rename and retains that expectation in the recovery context. If the
identity differs from the authorized source, the operation remains indeterminate; no automatic
rollback or recovery retry moves that name again. “Check Again” is observational for an unexpected
identity: it may clear the marker only after external action has independently restored the entry
to its recorded safe slot. Otherwise the operation remains fenced for an explicit recovery action.

Before the forward rename, App write-ahead persists security-scoped bookmarks for both exact
parents plus their literal leaves and no-follow directory expectations. It also captures a
mandatory bookmark for the selected item identity. Bookmark creation, resolution, and identity
validation must complete before mutation. The parent-entry locators authorize any recovery move;
the item bookmark is supplemental location evidence and never authorizes a name-based mutation by
itself. These authorities survive either parent moving after rename, including after `.didRename`
when both recorded workspace paths disappear. Any separately recorded display URL is never
authority and is never reopened to adopt an escaped location.
For this escaped-parent case, recovery may only use the verified parent authority to perform an
exclusive, no-follow anchored move back to the proven-missing original source under its still-valid
workspace parent. The outside location is never committed as a workspace destination. An
unresolvable, stale, mismatched, occupied-source, cross-device, failed, or indeterminate recovery
keeps the operation quarantined and “Check Again” actionable.

## App relocation and Trash transaction

Before a durable rename or move can publish to App state, App prepares one all-or-nothing
relocation for every affected current, cached, retired, and editor-bound session, deduplicated by
session identity and selected through retained locations. Destination ownership collisions,
unavailable or indeterminate authority, and any preparation failure reject the filesystem
transaction before App state changes. The destination scan is App-global rather than driven by
the affected-source records, so an unopened source cannot overwrite a cached, retired, detached,
editor-bound, LRU, prompt, observation, indeterminate-write, or operation/text-recovery spelling;
that includes pending multi-record text recovery, pending operation bundles, and operation records
whose retained bookmark could not yet be restored. Display-root candidates reserve App ownership
only and never become filesystem authority. Runtime ownership includes every resolved parent-entry,
item, staging, and reported-Trash locator in that locator's own retained-root coordinate system,
even when a bookmark followed the item outside the original workspace. Save Copy, creation, and
relocation all use symmetric, component-bounded overlap, with the retained filesystem's
case-sensitivity policy and canonical-equivalence folding: any requested entry, including an
ordinary file, conflicts with owned ancestors and descendants. An entry at `archive` therefore
cannot shadow owned recovery at `archive/post.md`, and a missing case/NFC alias cannot claim the
same recovery slot. Persisted display candidates provide the same fail-closed reservation before
bookmarks are restored but never authorize filesystem access.
Source-state exclusions use the exact old literal spelling, so a
spelling-only rename does not hide a distinct destination-state owner. The nonthrowing commit then
updates together:

- `DocumentSession` location and file kind while preserving exact source, saved-text baseline,
  dirty state, and object identity;
- session-cache keys, retired-session keys and canonical locations, and LRU dirty/recency state;
- anchored bindings or an explicitly authorized promotion from installed unanchored membership;
- autosave, external-inspection, external-resolution, and pending-application tasks plus their
  lifecycle and disk-event generations, so late work for the old location cannot commit;
- pending conflict text and coherent observed versions, deferred resolution intent, detached
  state, and current external/missing prompts;
- editor binding/installations and synchronizers, while retiring stale writer activation so the
  installation must reacquire against the relocated session revision; and
- a destination-prepared image document authority for the same retained file identity. The old
  parent/leaf authority is never carried across a move.

Legacy last-known hash or modification-date entries may be rekeyed only as bookkeeping when their
owning session relocates. PR #84 does not reintroduce the old URL-based save, external-change,
mtime, or hash authorization logic: writes and observations continue to use the retained
location/identity/digest contracts merged through PR #85 and PR #82.

Image placement holds an App namespace lease from its first filesystem side effect through the
last commit validation and synchronous Markdown publication. EditorKit reports one exactly-once
terminal result: a successful publication commits and releases the lease in that same MainActor
turn; every rejected, superseded, or dismantled path finishes asset cleanup before discard releases
it. Create, rename, move, Trash, and App termination therefore cannot enter or interrupt the
terminal interval and commit a now-invalid relative image path or abandon cleanup mid-rename/fsync.

Trash first rejects any affected dirty session or pending editor source before invoking the
recycler. Before staging, App durably records a pending phase with the exact source-parent
bookmark plus literal leaf, a mandatory expected-item bookmark, the root staging location, and
the affected text/session bundle. WorkspaceKit then creates and verifies a Core Foundation
file-reference URL for the exact selected identity, moves the exact selected lexical entry to a
unique hidden root-level staging leaf, and fences autosave, observation, writer-to-disk, and image
side effects for every affected session. The recycler receives the retained file reference through
`FileManager.trashItem`, not a reconstructed mutable staging-path URL. Controlled tests prove that
the reference continues to resolve the original object when the lexical staging path is replaced.
The Foundation handoff is nevertheless opaque and Darwin exposes no expected-inode Trash syscall,
so the final reference-resolution-to-namespace-mutation interval remains a platform residual rather
than an identity-atomic guarantee. Completion is postflight-validated against the reported Trash
result, source, and staging namespace. Before App/session cleanup, the returned Trash location must
produce a bookmark that resolves to the exact expected identity and the journal advances to
committed. Check Again re-resolves every parent/item/reported bookmark on each attempt;
present-but-unresolved locator data blocks release instead of falling back to a display URL. A
failed or unproven handoff retains the exact staged recovery when known; an unexpected identity is
never moved by an unsafe automatic reverse rename.

The Trash fence does not block native editor publication. Input accepted while the asynchronous
recycler is in flight stays in its existing `DocumentSession`. After a proven Trash commit,
unchanged clean sessions release their cache, retirement, binding, task, prompt, observation, and
image authority. Any session whose source revision changed during the handoff becomes
save-blocked detached recovery at its original exact URL; a background recovery session is
promoted when necessary so the newly typed source remains reachable, and autosave cannot recreate
the trashed path.

## Mutation recovery and termination

Creation, relocation, and Trash persist operation-level write-ahead context before the first
namespace-mutating syscall: exact source/destination locations, Trash staging, item and parent
expectations, failure and cleanup state, and all affected session records. Relocation additionally
persists both validated parent-entry locators and a mandatory item locator before the forward
rename, so a post-rename parent move cannot erase the only locator for the moved entry. Creation
persists its destination-parent locator and root staging path in `planned`, its exact staged-item
locator in `prepared`, and the jointly proven destination state in `committed` before activation.
Trash similarly distinguishes pending session commit from committed cleanup and retains the
verified reported-Trash locator.
Rename/move and Trash bundle their initial affected-session text before the rename or staging move.
The operation record
is removed only after the filesystem result and App/session/text state have committed.

Recovery is global rather than current-document-only. The banner continues to represent the oldest
deterministic operation after the user switches documents; “Show Editor Copy” returns to a
quarantined session, “Check Again” revalidates the exact retained candidates, and a zero-session
operation offers an explicit stop-tracking path after manual inspection. Resolving one operation
promotes the next. No new create, rename, move, or Trash may start while any operation remains
unresolved.

`WorkspaceWindow` renders recovery at the global window level when no document is open or recovery
storage failed to load. With an open document, an ordinary operation prompt uses the editor
placement. A restored zero-session operation therefore still exposes Check Again and Stop Tracking
without requiring a document to open successfully.

Reconciliation releases quarantine only for a proven state. A prepared or committed creation
requires its destination-parent and item authorities to agree on the literal logical destination
while the root staging entry is proven clear; an item located outside, at retained staging, or
behind an unresolved bookmark remains fenced. A relocation may restore the source
authority or transactionally commit the proven destination across session cache, retirement,
bindings, LRU, prompts, observation, writer activation, and image authority. Trash may restore a
proven staging identity to the source or finish a proven recycler destination. Ambiguous
source/destination pairs stay quarantined; “Keep Editor Copy” first persists exact editor source,
then converts only that session into detached missing-file recovery.

Operation and text recovery are stored outside the workspace under Application Support as
atomically replaced binary-property-list records. A write uses an exclusive temporary file, file
`fsync`, atomic rename, and recovery-directory `fsync`. On first creation, every new
`Application Support/Plainsong/<Recovery>` directory edge is created separately and the child and
parent are synced; a failed attempt is not considered repaired until retry re-syncs the full
Recovery → Plainsong → Application Support chain. Record removal syncs the directory even when an
idempotent retry observes `ENOENT`. Quarantine likewise re-syncs its parent when retry observes
that the prior rename already took effect. Because unlink can take effect before its directory
sync reports failure, App also immediately rewrites the exact current text or operation record on
any remove error; unresolved release durably reinstalls its operation context before returning the
cleanup error.

Successful operation-record removal and runtime release are one logical transition. Terminal
proof helpers may have reinstalled a freshly resolved context while validating the ordinary
success path, so App clears that exact installed context, its per-session recovery ownership, and
the indeterminate-session fence immediately after—and never before—the durable removal succeeds.
This prevents a completed operation from permanently blocking later saves, mutations, or quit.

If Save Copy has already committed and the session is clean and anchored, a text-record removal
failure remains visible and actionable instead of becoming a hidden permanent quit fence. The
exact recovery context is marked as requiring explicit Stop Tracking, later termination attempts
do not silently retry removal, and the current or globally queued recovery banner continues to
reach that session. Stop Tracking first durably upserts the latest exact text revision, then
renames only that record to a unique non-`.plist` quarantine sibling with descriptor-relative
`RENAME_EXCL | RENAME_NOFOLLOW_ANY` and fsyncs the recovery directory. App clears that record's
runtime context only after the quarantine is durable; any failure preserves the prompt, record,
and termination fence.

Text records preserve exact UTF-8 source, monotonic logical revision, original URL, file kind, and
reason. Runtime recovery sessions are strongly retained and promoted in a deterministic queue,
including multiple files edited during one directory Trash. If a standalone text upsert fails
while its operation journal remains, App synchronously advances only that session's bundled
snapshot without dropping sibling sessions. Promotion chooses the newest bundled, pending
standalone, restored, or live record by logical revision and then timestamp; every record in a
multi-session operation must succeed before the bundle is considered promoted. The bundle is not
cleared before durable operation-record removal, so a removal failure followed by new input still
has a journal fallback.

Rename and move establish the same dual-store guarantee before their namespace syscall. The
operation journal is attempted with every affected editor snapshot bundled, and every unique
session's standalone text record is attempted synchronously even if a sibling write fails. A
successful operation record therefore covers standalone failure; if the operation upsert fails,
sessions are quarantined only when every standalone snapshot is known durable. If neither store
can prove all snapshots durable, the relocation aborts before mutation without installing the
autosave fence, while the in-memory recovery remains actionable and termination stays blocked.

On restart each text record opens as dirty detached source with unavailable ownership proof, so it
cannot overwrite or adopt a replacement at the original path. Save Copy uses a newly anchored
destination parent; an explicit destination outside a temporarily stale workspace capture remains
available, while any destination that may be inside that workspace still requires the current
retained root authority.

A malformed or mismatched operation/text store is preserved untouched and globally fences save,
autosave, Save Copy, open/new/close, namespace mutation, image insertion, and termination. Native
editor input may remain memory-resident. The persistent recovery banner offers an explicit
stop-tracking action that atomically renames the entire unreadable store to a unique sibling,
fsyncs the parent, and never deletes the corrupt bytes. Only after that quarantine succeeds are
normal recovery loading and file access resumed.

A recycler-reported Trash URL is display-only after restart. When possible App stores a
security-scoped bookmark only after the reported entry matches the expected device, inode, and
kind. Restart must resolve that bookmark and reproduce the same expectation before the location
can prove Trash completion. Missing, stale-unrefreshable, unresolvable, or mismatched bookmark
authority keeps the operation actionable rather than recapturing the displayed URL. A stale
bookmark whose live resolved location is already proven remains usable for the current launch even
if refreshing its bookmark fails.

`applicationShouldTerminate` synchronously rejects termination when editor source is pending,
recovery persistence fails, a namespace mutation is active, or operation reconciliation remains.
Before a successful quit it saves ordinary writable sessions and verifies every dirty fenced or
detached session has a recovery record at its exact current revision. Thus input accepted while
Trash is in flight is either durably saved/recovered or the App remains open.

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
  paths remain distinct UTF-8 keys, literal ignore rules do not canonical-equate spellings, and no
  spelling suppresses or supplies another's overlay;
- completion current-file exclusion and ordering at the bounded sibling-read limit, proving a
  byte-distinct NFC/NFD sibling remains eligible and the first 50 reads are byte-deterministic;
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
- anchored and standalone delete/recreate recovery after switching to another file, proving the
  original cached session reaches arbitration with its detached fence intact even when A's exact
  identity/digest is restored, then Keep Mine clears matching fences and resumes Cmd-S/autosave;
- reusable retired anchored and standalone same-proof restoration, proving activation cannot clear
  detachment before arbitration and Reload remains required before save/autosave resumes;
- Keep Mine rebaselining from A to fresh C without changing local editor text, proving exact C
  becomes clean while byte-distinct, canonically equivalent A remains dirty, plus a clean
  quarantine whose local/observed Unicode spellings make the session/LRU dirty;
- async authority capture cancellation that releases a live descriptor-backed authority;
- post-capture root moved/symlink-replaced/directory-replaced normalized to `namespaceChanged`;
- complete returned-metadata equality for existing replacement and missing creation;
- mismatched request roots and A/B root, ignore-rule, overlay, and result separation;
- durable rollback versus typed indeterminate rollback;
- cancellation and temporary-artifact cleanup; and
- canonical bytes, moved/replacement bytes, destination identities, outside sentinels, and
  absent or intentionally retained artifacts for every adversarial path.

The PR #84 suites additionally cover invalid creation and relocation names, snapshot-parent
replacement, symlink traversal, root-staged exclusive file creation without an unjournaled writer
temporary, planned creation persisted before its first syscall, callback-before-publication,
planned/prepared/committed restart, stale and unresolved item/parent locators, and a retained-root
folder clone from a same-device `.itemReplacementDirectory` descriptor, source-name removal without a leaked temporary
path, pre-removal replacement preservation, final-removal-gap moved-source rejection, source mode
and readable-xattr mutation, repeated destination ctime/xattr policy validation, signed App
Sandbox folder creation with system xattrs, callback failure with exact root staging preserved,
startup zero-session reconstruction and global reconciliation/release UI, planned restart with
missing and occupied candidates, destination replacement before and after descriptor capture
without moving or deleting the replacement, staging substitution, destination-parent replacement
and post-rename escape, committed journal-removal failure, committed rename failures without reverse rollback,
actual moved-entry recovery, final rename with a destination parent moved outside the retained
root before publication, post-rename destination-parent escape with bookmark-authorized recovery,
literal leading/trailing whitespace creation and rename plus all-whitespace rejection, case-only
and NFC/NFD-only exact spelling publication with transactional App rekeying, App-global destination
ownership for unopened-source rename and creation including normal-file shadowing of a
recovery-owned descendant, a component-prefix sibling control, a detached equivalent-spelling
collision, escaped creation/relocation/Trash item-locator Save Copy ownership, missing
case/NFC-equivalent recovery ownership, dual-store relocation write-ahead failure in both
directions without short-circuiting sibling sessions, an image namespace
lease held through validation plus Markdown commit or cleanup, and Trash-in-flight typing observed
past the production minimum autosave delay,
file-reference
Trash with a replaced staging path, retained failed-handoff recovery, multi-owner App relocation,
dirty and pending-source Trash refusal, input accepted during Trash, global operation/text
recovery, multi-session fallback and newest-wins promotion, remove/reinstall fallback retention,
reported Trash bookmark proof, corrupt-store global fencing and byte-preserving quarantine,
actionable per-record cleanup failure and Stop Tracking quarantine, nested recovery-directory
fsync failure/retry, idempotent remove/quarantine durability, and termination veto.

The focused suites live in `WorkspaceAnchoredFileSystemTests`,
`WorkspaceNamespaceAuthorityTests`, `WorkspaceCoherentFileReaderTests`, and the
`WorkspaceFileWrite*Tests` files, plus `WorkspaceAnchoredItem*Tests`,
`AppStateWorkspaceDataIntegrityTests`, and `WorkspaceMutationTextRecoveryStoreTests`.
