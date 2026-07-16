# Phase 3 Workspace Search Plan

> **Status: IN PROGRESS. WS1, WS2, and WS3A are complete. PR #85 merged the WS3B
> filesystem-authority/write sub-gate, and Draft PR #82 is restacked directly onto that authority
> baseline as the headless multi-window lifecycle hardening PR; it was not superseded by a
> visible-sidebar branch. Headless WS3B overall, every visible Files/Search sidebar item, refresh
> work, WS3C, WS4, and the overall Definition of Done remain open.**
> This plan defines an in-process, ripgrep-style workspace search for Markdown authors,
> with the search model concentrated in MarkdownCore and WorkspaceKit and with a
> CI-verifiable sidebar workflow.
> WS2 is a package and AppState orchestration layer only; workspace search is not yet
> user-facing until WS3 adds the sidebar and navigation integration.

Created 2026-07-10. This is a Phase 3 candidate from `agent.md` section 14. It does not
change the accepted M0-M5 or Experimental WYSIWYG status.

## 1. Outcome

Ship fast, cancellable content search across an open folder workspace:

- `Command-Shift-F` opens and focuses a Search mode in the existing sidebar.
- Search covers Markdown and MDX files (`.md`, `.markdown`, and `.mdx`).
- Results stream into the sidebar, grouped by workspace-relative file path, with a line
  number, a bounded context snippet, and highlighted matching text.
- Selecting a result opens the correct file, synchronizes the file-tree selection, then
  selects and reveals the exact match in the editor.
- Dirty in-memory document sessions override disk content, so text is searchable before
  autosave completes.
- Rapid query changes, workspace refreshes, and file edits cancel or invalidate stale
  searches; an older task can never overwrite newer results.

“Ripgrep-style” means recursive, ignore-aware, streaming, deterministic, fast, and
cancellable. It does **not** mean launching an external `rg` executable or cloning every
regular-expression feature in the first release.

## 2. Product Contract

### 2.1 In scope

- Folder workspaces only. Workspace search is disabled when only a single file is open.
- Markdown content only: `.md`, `.markdown`, and `.mdx`, independent of the sidebar's
  **Show All Files** setting.
- Literal search with three case modes:
  - **Smart case** by default: a query containing a cased uppercase character is
    case-sensitive; otherwise it is case-insensitive.
  - Explicit case-sensitive.
  - Explicit case-insensitive at the model layer, even if the first UI exposes only a
    case-sensitive toggle over smart-case.
- Optional whole-word matching. Unicode letters, numbers, and underscore are word
  characters.
- Non-overlapping matches, ordered by workspace-relative path and source position.
- One-based line numbers in the UI and UTF-16 `NSRange` values for editor navigation.
- LF and CRLF documents, CJK text, emoji, combining marks, and files without a trailing
  newline.
- Search results from unsaved warm sessions. The App captures immutable text overlays on
  the main actor before handing work to WorkspaceKit.
- Hidden/ignored/generated path exclusion, root-containment enforcement, skipped-file
  reporting, and explicit result truncation.

### 2.2 Deferred

- Workspace-wide replace.
- Search outside Markdown/MDX files.
- Search history or persisted queries.
- A long-running indexing daemon.
- Fuzzy filename search; this is content search, not Quick Open.
- Full ripgrep-compatible regular expressions.
- A “search ignored files” override.

Regex should be a separate Phase 3 gate after selecting a cancel-safe engine.
`NSRegularExpression` does not provide ripgrep's linear-time guarantee, and a detached
task cannot reliably interrupt a pathological synchronous match. Adding a regex engine or
bundled executable would require a dependency and Decision Log review.

### 2.3 Initial safety limits

Use named configuration values so tests can lower them without constructing huge files:

- Maximum searchable file size: 512 KiB. Release probes at 1 MiB crossed one second for
  dense rejected whole-word candidates; the lower admission cap bounds one synchronous
  file-level call while MarkdownCore keeps 1 MiB stress coverage. Raising it requires
  measured release-build evidence or a cancel-safe indexed/chunked design.
- Maximum query length: 256 UTF-16 units. The App should present this as validation, not
  as an empty-result state; raising it requires new adversarial Unicode timing evidence.
- Maximum matches per file: 500.
- Maximum matches per query: 10,000.
- Ordered read window: 4. The configured value is clamped to at least one; the number of
  in-flight reads plus completed read payloads buffered behind an earlier path never
  exceeds the stored limit.
- Ignore-rule reads are bounded to 128 files and 64 KiB per file (including one extra
  byte used to detect an over-limit file).
- Maximum reported and retained skipped-file details: 100. The summary retains the exact
  skipped total and reports how many details were omitted.
- Maximum progress events: 100. The configured value is clamped to at least one.
- Query debounce in the App: approximately 200 ms.

Reaching a match-count limit is a successful but truncated search, not a fatal error. An
overlong query is a validation state; an oversized file is skipped. The sidebar must show
those states plus counts of unreadable or invalid UTF-8 files instead of presenting any of
them as “no matches.” Once a readable file proves the global match limit was exceeded, the
producer enters an explicit accounting-only state: it emits no more file results and makes
no more MarkdownCore matching calls, but it continues the same bounded, path-ordered read
window through every remaining plan item. Readable, ignored, disappeared, unreadable,
invalid-UTF8, and oversized files therefore still contribute to exact terminal counts and
instrumentation, and successful progress still finishes at `N / N`.

The service uses a lossless `.unbounded` `AsyncStream` buffer, but one request has finite
production. Let `N` be its Markdown/MDX candidate count, `G` the effective nonnegative
global match limit (`max(0, maximumMatchesPerQuery)`), `S` the skipped-detail cap, and `M`
the maximum progress-event count. At most
`min(N, G) + min(N, S) + min(max(N, 1), M) + 1` events are produced: one file-result event
per matching file (and at least one match per such event), capped skipped details,
coalesced progress, and one terminal event. More precisely, a successful request produces
`R + min(K, S) + P + 1` events for `R` result files, `K` skipped files, and `P` progress
events. Invalid requests produce one validation event. Cancellation is silent and may
produce only a prefix of the valid-request bound.

## 3. Current Repository Constraints

- `WorkspaceDirectoryScanner.snapshot(root:)` scans off the main actor, classifies
  workspace entries, and checks cancellation during enumeration. AppState retains the raw
  snapshot plus a monotonic workspace generation; root and generation checks reject a
  cancelled or stale scan before it can apply state.
- The scanner skips hidden entries and package descendants but does not process
  `.gitignore`, `.ignore`, or common generated/vendor directories such as `node_modules`.
- `WorkspaceRootContainment` remains the shared symlink-resolving containment boundary for
  completion, assets, and initial workspace-search candidate canonicalization. Search then
  binds the canonical lexical path to the request's immutable no-follow filesystem authority.
- `DocumentSession` owns canonical in-memory text, while `AppState.sessionCache` retains up
  to eight warm sessions keyed by the contained, symlink-resolved physical target URL.
  WorkspaceKit must receive immutable overlays rather than reading main-actor sessions
  directly.
- `WorkspaceSidebar` is a fixed-width view inside an `HStack`. Risk R17 prohibits casually
  restoring the `NavigationSplitView` path that previously caused an AppKit constraint
  loop. Search should keep the stable shell and may increase the fixed width from 220 to
  roughly 280 points if needed.
- `MarkdownEditorView` keeps its selection as private state. The existing
  `EditorScrollProxy.scrollToLine(_:)` cannot select an exact match and can target the old
  text view during a cross-file switch. A document-aware, tokenized navigation request is
  required.
- The current CI job does not install ripgrep. `make test` already runs all four SwiftPM
  packages, hosted App tests, PerformanceTests, and preview tests on macOS.

## 4. Architecture

| Layer | Responsibility | Proposed surface |
|---|---|---|
| MarkdownCore | Pure query semantics, text matching, UTF-16 ranges, line mapping, bounded snippets | `TextSearchQuery`, `TextSearchMatch`, `TextSearchEngine` |
| WorkspaceKit | Candidate selection, ignore policy, containment, reads, cancellation, streaming, limits, deterministic aggregation | `WorkspaceSearchRequest`, `WorkspaceSearchEvent`, `WorkspaceSearchSummary`, `WorkspaceSearchService` |
| App | Debounce, task lifecycle, dirty overlays, latest-generation arbitration, sidebar state, future active-search FSEvent refresh | `AppState+WorkspaceSearch`, `WorkspaceSearchState` |
| EditorKit | Apply an exact selection only after the requested document text is installed, then reveal and focus it | `EditorNavigationCommand`, `EditorNavigationRequest` |

The implemented WS3B App lifecycle retains the `Task` that consumes each event stream and
explicitly cancels that Task before replacing a query, closing or switching a workspace, or
discarding search state. Merely breaking out of or abandoning `for await` iteration is not a
supported producer-cancellation mechanism for the existing `AsyncStream` API.

The dependency direction remains:

```text
App -> WorkspaceKit -> MarkdownCore
App -> EditorKit
```

MarkdownCore must not know about URLs or files. WorkspaceKit must not know about SwiftUI or
STTextView. App must not import STTextView types.

### 4.1 MarkdownCore model

The exact names may follow Swift API Design Guidelines, but the model needs equivalent
capabilities:

```swift
public struct TextSearchQuery: Sendable, Equatable {
    public let pattern: String
    public let caseSensitivity: TextSearchCaseSensitivity
    public let wholeWord: Bool
}

public struct TextSearchMatch: Sendable, Equatable {
    public let range: NSRange
    public let line: Int
    public let preview: String
    public let previewMatchRange: NSRange
}
```

The engine should scan forward without rescanning the complete source prefix for every
match. Snippet clipping must retain the full match, prefer grapheme-safe cut points, and
keep the preview highlight range valid after adding ellipses. Context is capped at 1,024
UTF-16 units per side. If the match occupies only part of a source grapheme and reaching
that grapheme's boundary would exceed the per-side cap, the engine uses the exact-match
boundary on that side rather than copying the entire pathological context into every result.
After a rejected whole-word hit, matching advances directly to the next composed boundary
whose predecessor is not a word character; starts inside the same word cannot succeed and
must not be enumerated one UTF-16 unit at a time.

### 4.2 WorkspaceKit model

A request should contain only immutable, Sendable data:

- one immutable `WorkspaceFileSystemRootAuthority` as the sole filesystem root; its captured
  original URL may supply security-scoped access, but the request accepts no independent root
  URL for candidate planning, ignore files, overlays, or reads;
- immutable `WorkspaceFileSnapshot`;
- a root identity string plus workspace/query generations used only as App lifecycle tokens,
  never as filesystem authority;
- query and configurable limits;
- a validated `WorkspaceSearchOverlayCollection` containing normalized relative paths,
  indexed by their exact UTF-8 bytes, and immutable unsaved text.

The service emits partial per-file results and a final summary. Result application is valid
only when root identity, workspace generation, and query generation still match the active
App state.

The reusable WorkspaceKit filesystem foundation is specified in
`docs/workspace-filesystem-contract.md`. Workspace reload captures one descriptor-backed root
authority together with its snapshot off the main actor. When reload auto-opens a selected
document, location construction and the exact file byte load remain rooted in
`capture.rootAuthority`. The loaded descriptor identity and exact-byte digest become the
session's anchored binding, and a cached current/warm session is reconciled from the loaded
activation file instead of returning early. Because the load may suspend, the selected root
spelling is proved a second time after the load and immediately before the prepared activation,
capture, installed generation, and tree are committed without a main-actor suspension. A failed
proof or activation installs none of the stale capture. A current-session/state-location change
during that suspension cancels publication, and cached/retired activation source arbitration is
repeated after the final proof before the uninterrupted commit. An external namespace mutation can still
race after that last proof, so this is not claimed to be identity-atomic; retained authority and
later fail-closed validation keep such a race from redirecting a consumer to root B. Main-actor
search-request construction remains filesystem-free. Production reads walk lexical
root-relative paths through a retained no-follow descriptor chain and validate the root, every
ancestor, the final parent, and the leaf before publishing bytes.

Each production disk result, and each overlay result whose physical destination was validated,
carries `WorkspaceSearchFileAuthority`: the same retained location plus identity sampled from
the exact read/validation descriptor. Workspace-search-result activation consumes that retained
location and identity; after activation it compares the installed session binding's location
with the accepted target before fingerprint/range navigation. File-tree/sidebar opening derives
its location from the installed authority. Completion refresh retains the installed authority
and current binding location for sibling reads; if the current session binding belongs to a
previous authority, refresh fails closed to current-document-only completion and reads no
siblings from the installed replacement root. Reload rejects a previous-authority location that
lexically collides inside the new root, while treating an outgoing retained location outside the
new root as unrelated so a normal workspace A-to-unrelated-workspace B switch can install B's
first editable file. None of these paths decides what to read or save by resolving a mutable
post-install root or session URL.

Every `WorkspaceSearchFileResult` carries a `WorkspaceSearchContentFingerprint` computed
from the exact `String` passed to `TextSearchEngine`. Its digest is the 64-character
lowercase hexadecimal SHA-256 of that string's UTF-8 bytes, accompanied by the exact UTF-8
byte count. Disk text and dirty overlays use this identical algorithm. The public pure
`WorkspaceSearchContentFingerprint(text:)` initializer lets WS3 fingerprint the activated
`DocumentSession.text` before applying a range. Snapshot identity, modification date,
Swift `hashValue`/`Hasher`, and caller session versions are not content identity; no session
version is retained by the WS2 result model. If a disk file changes after the snapshot but
before its read, its result fingerprints the newly read and searched content.

Every production result also carries the exact immutable `WorkspaceSearchFileAuthority`
used for its searched content: the retained root authority and byte-exact normalized relative-path
key plus the physical device/inode identity sampled from the descriptor that read disk bytes
or validated an overlay. App activation must consume this token rather than reconstructing
authority from a mutable URL. It performs one anchored load that still expects that physical
identity, then prepares the session fingerprint and exact range before any transactional commit.
Compatibility readers used by tests may omit the token; App activation fails closed when a
retained result does not have one.

Dirty overlays are validated before a request is built. `WorkspaceSearchOverlay` rejects
empty, absolute, and traversing paths and stores a normalized workspace-relative path.
`WorkspaceSearchOverlayCollection` rejects dictionary key/path mismatches and rejects every
exact-byte normalized collision instead of choosing a winner by input or dictionary iteration
order; for example, `post.md` and `./post.md` cannot coexist. Canonically equivalent NFC and
NFD spellings remain separate UTF-8 path keys, so an overlay can neither replace nor be applied
to the other spelling. Valid overlays continue to take precedence over disk content. Candidate
deduplication, ignore-file ancestor enumeration, and deterministic path ordering use the same
byte-exact key. An anchored dirty session is eligible only when its retained
root authority equals the installed authority used for the request; moving root A and placing B
at the old spelling cannot inject a cached A session's dirty text into B's search.
Completion metadata uses that byte key for current-file exclusion and ordering before the bounded
50-sibling frontmatter read. A canonically equivalent but byte-distinct sibling therefore remains
eligible, and snapshot insertion order cannot choose which siblings fall inside the read cap.

Workspace document identity keeps one physical-target policy. Initial in-root aliases are
resolved and containment-checked during candidate planning, then expressed as one canonical
lexical root-relative path; aliases to the same target collapse to that candidate, and an
outside-root target remains a typed `symlinkEscape`. Once the canonical path is bound to the
request's captured root authority, production reads never resolve the alias or another mutable
URL again. Every component is opened no-follow through retained descriptors, so a symlink,
rename, or replacement introduced after planning fails closed. Dirty overlays use the same
byte-exact normalized candidate key and are accepted only after the exact physical leaf is validated.
Candidate, skipped, progress, and terminal counts remain internally consistent.

Search reads must:

- accept only snapshot entries classified as editable Markdown;
- resolve every candidate against the real workspace root;
- reject `..`, outside-root alias targets, and any symlink substitution after authority binding;
- prefer a dirty overlay to disk;
- skip a file that disappears, becomes unreadable, is invalid UTF-8, or exceeds the byte
  cap while continuing other files;
- check cancellation between enumeration, reads, and file-level matching;
- sort published state deterministically even if reads complete out of order.

Reads are published in path order through a bounded window whose invariant is
`inFlightReadCount + bufferedCompletedReadCount <= maximumConcurrentReads`. Scheduling a
replacement read waits until the ordered consumer removes a completed payload when the
window is full. Completion instrumentation reports maximum concurrent, buffered, and total
outstanding read counts. Once decoding returns, the ordered buffer retains only the
`String` payload rather than a full `Data`/`String` pair, and releases that string after
matching/publication; WS2 has no text cache.

Expected file-level problems remain typed skipped-file events and do not fail a query. A
successful valid request emits exactly one `.completed` terminal event. An unexpected
producer fault emits exactly one
`.failed(context, .unexpectedProducerFailure)` terminal event. Consumer cancellation emits
neither terminal event. Security-scoped access and every structured child read are stopped
or cancelled on all terminal paths. A `CancellationError` is silent only when the producer
Task is actually cancelled; the same error thrown independently by a reader is an unexpected
producer failure. Early termination requires explicitly cancelling the Task consuming the
stream. The contract does not claim that `break` invokes `onTermination` or cancels the
producer.

Skipped-file totals remain exact after detail capping. Only the first 100 path-ordered
details under default limits are emitted and retained; `omittedSkippedFileCount` and
`areSkippedFileDetailsTruncated` expose the remainder. Progress uses the deterministic
stride `ceil(N / M)` for `N` candidates and a configured maximum `M >= 1`, is monotonic and
deduplicated, and always includes the final producer progress value on successful
completion. File-result and terminal events are never dropped.

### 4.3 Ignore policy

Workspace search must not traverse a typical Astro or Next.js dependency/build tree by
default. The policy should cover:

- hidden files/directories and package descendants;
- common generated/vendor directories (`node_modules`, `.build`, `.next`, `.astro`,
  `DerivedData`, `dist`, and `build`);
- root and nested `.gitignore`/`.ignore` rules needed for directory patterns, rooted
  patterns, `*`, `?`, `**`, and negation.

The supported rule subset must be documented and tested. Do not silently claim complete
Git ignore compatibility if edge cases remain unsupported.

**Implemented WS2 subset.** Search first applies hard, non-negatable exclusions for hidden
path components, package descendants, and `.git`, `node_modules`, `.build`, `.next`,
`.astro`, `DerivedData`, `dist`, and `build`. It then loads relevant ignore files from the
workspace root through each candidate's parent directory, in deterministic directory order,
reading `.gitignore` before `.ignore` within one directory. At most 128 ignore files are
attempted and each read is capped at 64 KiB plus one detection byte; unavailable, invalid
UTF-8, oversized, or escaped ignore files contribute no rules.

Candidate paths are containment-checked during planning and revalidated immediately before a
disk open. Empty, absolute, traversing, or escaping paths are reported as typed skipped files
rather than being read.

Rules support blank lines, `#` comments, leading `/` rooted patterns, trailing `/`
directory-only patterns, `*`, `?`, `**`, `!` negation, nested base directories, and
last-matching-rule-wins behavior. `*` and `?` never span `/`; `**` spans zero or more path
components. Literal pattern characters match only identical UTF-8 bytes; Swift's canonical
equivalence therefore cannot make an NFC ignore rule suppress an NFD candidate (or vice versa).
Pattern `*` is recognized as a wildcard before literal-byte comparison, so an identical `*` byte
in a filename cannot consume the pattern token and disable the wildcard's backtracking anchor.
This is deliberately not complete Git ignore compatibility: bracket classes,
backslash escaping, global/exclude files, and Git's traversal rule that prevents a child from
being re-included beneath an ignored parent are unsupported. Because WS2 filters an immutable
snapshot rather than pruning a filesystem walk, a later negation may re-include a child.

### 4.4 App and editor navigation

The sidebar gains two modes inside the existing stable shell:

- **Files** preserves the current tree, file information, and frontmatter panel.
- **Search** presents the field, case/word controls, progress, grouped results, and
  summary/error states.

Files-tree parent grouping and default-filter ancestor visibility use UTF-8 byte keys. If a
snapshot entry has no resource identity, its fallback node ID is a namespaced ASCII hex encoding
of the exact relative-path bytes, so NFC/NFD directories neither share children nor expansion IDs.

`Command-Shift-F` selects Search mode and increments a search-focus request token.
`Command-F` remains the focused editor's single-file find action. Keyboard selection and
Return should open results; every result row needs an accessibility label containing the
path, line, and snippet.

Opening a result is a two-stage action:

1. Find the relative-path node, update `WorkspaceFileTree.selectedNodeID`, and activate
   the corresponding session.
2. Send a monotonically identified editor navigation command containing the target
   document identity and UTF-16 range. EditorKit applies it only after that document's
   text is installed, sets the selection, scrolls it visible, and focuses the editor. A
   cancellation command in the same `UInt64` ordering domain clears older pending work;
   older or repeated navigation and cancellation commands are ignored.

Acceptance and execution are separate. A stale root/workspace/query context or an event that
is not the retained result/match is ignored without disturbing unrelated navigation. Structural
target checks and failures before a retained-file read remain side-effect free. Once App has made
one coherent retained-authority read for a reusable cached or retired session, however, that read
is also an external disk observation: before fingerprint or range validation can reject navigation,
App advances the session's disk-event generation and either adopts the accepted observation and
its proof or records a conflict while retaining the prior proof. That observation may therefore
update the destination session's external-change state and cancel that session's autosave under
the normal conflict rule; it still cannot change the current document, tree selection, navigation
command, search task, or unrelated session work/prompts. Cancellation is forwarded into every
detached authority-capture/read/preparation child and is checked again before publication, so an
evicted task cannot finish later with a usable prepared observation. Missing nodes and pre-read
open/detach/identity failures leave all prior state unchanged. If that coherent read instead proves
that a cached or retired B now names an inode already owned by A, App marks B detached and
save-blocked before advancing its disk-event generation and cancelling B's older inspection; a
late stale B result cannot restore it. A newly loaded candidate has no reusable state to detach and
remains invisible. Fingerprint mismatch and invalid
ranges preserve the navigation/UI transaction,
but cannot erase an observation already read from disk. Only a fully validated attempt emits a
newer cancellation, commits the session/tree switch and task transfer, then emits an even newer
exact-range navigation. Reactivating the already-current session remains a document-transition
no-op before that successful navigation.

The result carries the exact searched-content fingerprint. App fingerprints the prepared
destination source before activation; a digest or UTF-8 byte-count mismatch rejects that attempt
without jumping, cancelling navigation, or implicitly replacing the active search. A
document/session version may still arbitrate lifecycle elsewhere, but it is never proof of
content equality. In Experimental WYSIWYG, programmatic selection must reveal the matching
source region without mutating source text.

**Implemented WS3A subset.** EditorKit now accepts an optional opaque document identity and
a monotonic `EditorNavigationCommand` carrying either an `EditorNavigationRequest` or a
cancellation ID. A newer command supersedes older pending work; cancellation clears pending
range-navigation effects and their retry tasks but does not cancel a prepared document transition,
while older and repeated commands are idempotently ignored. Per-update candidate generations, not optional-identity equality, keep the installed
model bindings pinned through IME composition and replace the binding, identity, and installed
generation together only after the candidate's literal UTF-16 text is present. Exact raw
UTF-16 selection, scrolling, and focus occur only for that installed candidate after IME has
ended and the editor is window-attached. Invalid ranges are rejected without clamping. At
the WS3A landing point, App ownership, fingerprint arbitration, sidebar behavior, tree
synchronization, shortcuts, and refresh lifecycle remained pending WS3 work; WS3B advances
only the headless App subset below and remains open at this landing point.

**Implemented WS3B lifecycle foundation (gate still open).** MarkdownCore exposes one
literal exact UTF-16 source
comparison used by every `DocumentSession`/App text gate, so canonically equivalent but
raw-different edits advance versions, dirty state, and text delivery. AppState owns a focused
headless `WorkspaceSearchState`, an injected stream provider, the approximately 200 ms
debounce, and the exact Task consuming each stream. Query replacement, workspace generation
changes, close/switch, empty-query clear, and teardown explicitly cancel that Task;
root/workspace/query context checks gate every event, and task-token checks prevent an older
cleanup from touching newer state. Workspace reload captures the retained snapshot and its
single descriptor-backed filesystem authority together off the main actor, generation-fences
installation, loads optional activation bytes/identity/digest through that same authority, and
reconciles even a cached current session from that loaded file. A second selected-root proof runs
after the activation load immediately before the uninterrupted main-actor commit. Cached or
retired reuse additionally requires any retained binding or exact re-homed quarantine location
to equal the prepared activation location; URL equality cannot rebind A to replacement B. Requests add
validated immutable dirty overlays from current and warm Markdown/MDX sessions without
selecting another root, and request construction on the main actor stays filesystem-free.

The App/editor bridge carries an opaque binding ID distinct from optional navigation identity,
plus a second opaque installation ID generated once per EditorKit coordinator lifetime.
Installed/revoked events carry the exact pair and remain idempotent, but installation membership
alone does not grant source-write authority. Every editor publication now carries that exact pair,
the App-owned model revision and literal raw source on which the buffer was based, and the new raw
source. The ordinary `Binding<String>` setter has no App mutation authority.

AppState owns one exact writer installation per session. Every activation supplies the
coordinator's exact `EditorDocumentSourceSnapshot`; App returns its current snapshot and allows
AppKit's native mutation only when that exact installation owns the writer role and its opaque
App-owned monotonic revision is current. That current-revision proof is constant-time and performs
no App-source or native-buffer scan. After authorization, `DocumentSession` uses optimized literal
UTF-16 equality for exact no-op and persisted-baseline dirty checks; other literal comparisons serve
stale synchronization, revision-only rekey, rejection, and recovery. A stale coordinator is synchronized
and asked to retry before mutation, without stealing writer authority or leaving a rejected caller blocking another installation.
When only session metadata advanced the revision while the raw source and native view remain exact,
including same-session Save Copy rekey, EditorKit synchronizes and reacquires from the returned
snapshot inside that same pre-mutation request. A content-stale view instead restores App's current
source and rejects the native event before it can edit an unintended range.
Transfer is also refused while the previous writer has marked or other unsynchronized source, and
exact release/revoke cannot consume another coordinator's ownership. Two coordinators may stay
installed and mirror the model, but only the current writer can publish. The current-revision path
also skips eager whole-buffer UTF-8 transcoding and is covered through the real App source contract,
coordinator, and native view by a hosted public `MarkdownEditorView` local hard `<16 ms` 1 MiB
gate covering ordinary input, re-entrant pair insertion, and several scheduled marked-text
updates with zero App-source or native-storage full comparisons; hosted timing remains
informational under R15. Selection-only closing-delimiter skip-over never enters writer or
source-publication state and changes only the caret. A legitimately older marked-source
publication uses
literal UTF-16 three-way reconciliation so non-overlapping accepted edits survive exactly once;
insertions exactly at either half-open replacement boundary merge deterministically, while
strict-interior overlaps conflict. A repeated-source edit is merged only when its optimal
matched-offset alignment is unique; ambiguous offsets fail closed. Unsafe reconciliation restores
the coherent current view, installed
snapshot, model, writer/pending state, autosave eligibility, and dirty overlay rather than parking
an accepted native edit indefinitely.
Toolbar commands, completion, smart paste, and image insertion all acquire exact writer authority
through the same preflight before mutating native source. Async image insertion completes that
preflight before starting any asset side effect and carries the exact binding/installation-scoped
authority across its suspension; an initially rejected window therefore creates no asset, while a
later supersession cannot publish through another installation's authority and moves any placed
bytes out of their Markdown-visible name into a surfaced recovery artifact.
App placement is transactional: it stages with exclusive creation, publishes without replacing an
existing name, and retains descriptor-bound identity, byte-count, and SHA-256 receipts. Before
quarantining cleanup, it first proves that the published leaf still names the created inode; an
obvious replacement is preserved in place. The recovery rename is fsynced before any open or
validation, but Darwin cannot atomically return a descriptor for the entry it renamed. Every
successful recovery rename therefore reports an unknown/unavailable rename-acquired artifact and
separately reports any post-fsync current occupant—including a hard link to the known created
inode—from its own snapshot and retained descriptor. The same split applies when directory `fsync`
fails. Cleanup never performs a second check-then-rename restore because `RENAME_EXCL` protects only
the destination, not the mutable source identity. The retained created-asset descriptor is reported
separately whenever that inode is still linked elsewhere. Darwin also has no identity-conditional
unlink, so exact created bytes and same-inode rewrites remain surfaced under a recovery name instead
of entering a check-then-unlink race.
Descriptor-current path resolution reports a moved assets directory accurately; if its current
visible path cannot be proven, the issue reports an unavailable path plus retained identity and
leaf hint rather than the stale captured URL. Symlink, directory, and otherwise unopenable racers
derive their visible parent-plus-leaf location from the retained directory descriptor only while
that leaf still proves its observed identity; a later occupant never supplies the rename-acquired
artifact's reported path. Namespace and descriptor-link inspection are explicit three-state results: only
`ENOENT` or a successful `st_nlink == 0` proves absence, while other filesystem errors surface an
indeterminate artifact. A successful recovery rename always triggers a workspace refresh, including
when placement itself fails and carries the rollback disposition back to App state. A placement
rollback that preserves original or preflight-discovered artifacts also carries refresh provenance:
the successful-placement refresh has not happened yet, even when cleanup itself performed no
additional namespace mutation.
Changed, indeterminate, or race-replaced bytes are never hidden or unlinked.
The App-provided inserter reads an exact document-authority cache keyed to the retained session
location and identity. Descriptor-chain construction occurs before each coherent document read,
is post-validated against the loaded identity and namespace, and travels with that observation into
binding adoption; adoption itself never reopens the path. An exact existing cache remains the
authority for a reusable session, so a same-inode replacement observation cannot substitute a new
parent chain; a changed leaf can advance only when its prepared authority has the same retained
parent lineage. An existing session with no lineage cache stays fail-closed. A durable atomic save
rebinds the new leaf identity through the already retained parent descriptor or clears the cache on
failure. Save Copy captures and validates the destination parent before its writer starts, binds the
durable leaf through that retained parent, and installs the resulting authority before session
adoption. If a durable commit can no longer bind that leaf, the exact session is re-homed into
write-blocking reconciliation with the durable metadata and cleanup artifact retained; it is not
reported as an uncommitted save, and the reconciliation error includes retained or
removal-indeterminate recovery-artifact location details. SwiftUI document-binding and
image-inserter getter reads perform no security-scope, open,
or validation work, and a cache miss stays fail-closed rather than recapturing a replacement path.
The captured authority includes the
descriptor identities of the workspace-root-to-document-parent chain before suspension and never
re-derives placement authority from a later occupant of mutable `currentFileURL`. The
asset-directory lease similarly retains every root-to-assets component identity and proves that
the live namespace still names its terminal descriptor immediately before and after publication.
Moving or replacing the document parent or asset directory therefore fails closed; a post-publish
failure rolls back through the leased descriptor into a visible surfaced recovery name and returns
no Markdown path for bytes that landed under a displaced directory. The placement transaction keeps that document authority, every
created-asset receipt, and every existing in-workspace file reference alive. While the async writer
lease remains held, EditorKit asks the App to revalidate every component chain, leaf identity, and
content digest off-main immediately before the Markdown mutation, then rechecks exact editor
context/source and commits synchronously in the same MainActor turn. A moved/replaced namespace
therefore discards the transaction without publishing a stale Markdown path. A workspace-local
file reference captures its descriptor authority before reading size or bytes, hashes only through
that descriptor, and validates the parent/leaf namespace before and after the read and again before
publication. File-based insertion also keeps the supplied literal URL through
containment and no-follow validation, avoiding a Foundation `/private/var` to `/var` rewrite that
would turn a valid descriptor-canonical spelling into an `O_NOFOLLOW_ANY` failure.
Marked-text commit provenance retains the initial selected replacement span for AppKit's
`.notFound` path, but uses the exact delegate-confirmed replacement location when AppKit performs
an explicit replacement before commit. Selection-only or rejected mutations discard an
unconfirmed capture, and a direct unmark clears it after the native callback turn, so no stale
replacement range can redirect a later composition.

EditorKit still reports installation only from a successful `finishDocumentTransition` after the
exact candidate source is live; prepare does not transfer ownership. If marked or pending source
defers that finish, the coordinator retains the newest complete candidate generation including its
exact source snapshot, selection, document identity, binding/lifecycle callback, and navigation
command. After the old document's IME source publishes to its exact active or retired session, an
explicit yielded retry installs the destination source, binding, identity, selection, and lifecycle
once without another representable update. A newer candidate supersedes the older one, and
dismantle or explicit editor teardown discards the deferred candidate and retry task. A newer
`EditorNavigationCommand.cancel` clears only obsolete range-selection work: it never suppresses the
destination installation. Contract-free public Binding candidates refresh source and the
non-navigation selection from their live Bindings before retry, so neither same-document IME nor a
changing cross-document destination can reinstall a frozen pre-composition value.

Pending editor source is tracked by exact installation from the first deferred synchronization
until publication succeeds, composition is explicitly abandoned, or that installation revokes.
Duplicate begin/end events are no-ops and teardown cannot strand pending state. Pending source
blocks explicit save and autosave even while the model still appears clean. Search-result
activation likewise treats the exact pending editor/native source as local authority regardless of
the session dirty flag: a differing coherent disk observation must enter external-change
arbitration rather than replace the retained proof or install disk bytes over unpublished source.

Retirement and active-session state share one session-owned exact-state-URL registry whose record owns
the retained location and proof, exact
`DocumentSession`, binding IDs, awaiting installation pairs, task state, and any required shared
old-workspace authority owner. Close/switch collects every live installation across sessions,
including standalone files with no workspace authority. Several retirements from one workspace
share one reference lifetime, and the underlying security-scoped authority stops exactly once
after the final dependent retirement saves, resolves, or is deliberately discarded. Reopening a
retired URL consults this registry before disk loading and reactivates the exact session; duplicate
active/retired ownership is an invariant failure. Later workspace or standalone transitions
preserve older retirements and their autosave/statistics work. No deferred conflict, prompt,
autosave, save, recovery, or retirement lookup re-resolves the mutable filesystem path after this
authority is retained; only validated Save Copy atomically rehomes it. App generic writes remain
current-session-only, while an exact authorized writer may commit raw source to its own active,
detached-current, or retired session without touching the replacement document.

External-change conflicts are session-scoped by the canonical URL entry in
`pendingExternalTexts`, not by whichever banner is currently visible. Autosave and explicit
`save(session:)` reject that exact session even while another document is current. LRU
eviction, workspace retirement, and close paths retain or block on the dirty conflict rather
than overwriting disk or silently dropping the session. Reload restores the external text as
clean; Keep Mine performs and adopts a fresh observation, accepts the latest observed version
(for example C after an earlier B prompt), clears matching conflict, detached, and missing-file
fences, and restores save/autosave eligibility. If a clean quarantined session's local source
differs byte-for-byte from that observation, Keep Mine marks both the session and its LRU record
dirty before scheduling autosave, so the UI cannot claim a false clean state. The accepted
observation also becomes the session's saved-text baseline without replacing or publishing the
current editor text: editing back to C becomes clean, while editing back to pre-conflict A remains
dirty. If a detached cached or reusable retired session is reopened after the user switched to
another file, activation retains its old authority/proof and routes the recreated leaf through
this same arbitration; it does not reject the session before Reload/Keep Mine can be offered, and
the detached fence remains until one of those explicit resolutions succeeds. This arbitration is
required even when the restored leaf has the same descriptor identity, digest, and bytes as A,
because detachment invalidated the session's saved baseline.

Binding registration cleanup is exact and idempotent. A live retired installation retains its
registration; completed, discarded, evicted, and otherwise closed sessions release only their own
registration. A matching exact revoke can finish its retirement, while duplicate or stale revokes
cannot clear another installation.

Installed and standalone managed sessions retain the exact authority location, descriptor
identity, and exact loaded-byte digest. Standalone proof also captures installed-workspace
membership when present. Cmd-S/autosave uses typed `existingContent(identity, digest)` through
that retained location instead of resolving or reinspecting a session URL; unavailable, deleted,
replaced, or changed-content proof fails closed. Every Save Copy destination establishes one
no-follow `WorkspaceFileSystemLocation` before writing and consumes the typed outcome directly.
Save Copy reuses its one target inspection for both ownership arbitration and the first writer
expectation: a regular file is `.existing(identity)` and an absent leaf is `.missing`; the first
attempt is never widened to `.existingOrMissing`. Outside-workspace final symlinks are rejected
instead of being followed by a legacy save. Descriptor-derived physical identity detects
hard-link ownership across current, cached, retired, editor-bound, and unanchored standalone
sessions. Arbitration never re-inspects mutable `session.fileURL`. A source session may Save Copy
to a proven-missing destination only when its retained authority/location equals that destination;
literal path spelling is compared by UTF-8 bytes, so NFC/NFD spellings do not become an accidental
self-exemption. Canonically equivalent App-visible paths remain protected even when cached,
retired, editor-bound, or quarantined owners belong to different authorities. Case folding is
applied only when the destination parent reports a case-insensitive filesystem, so distinct case
spellings remain valid on case-sensitive volumes. Existing aliases, hard links, and every other
session remain protected. Only the source session's old state is removed after durable success.

An external notification first performs one coherent authority-bound read through the retained
anchored binding or standalone proof, then compares its literal location, descriptor identity,
and SHA-256 digest before adopting anything. mtime, FNV, URL recapture, and a cache/retirement
hit do not authorize a proof replacement. For a dirty session, any unaccepted identity or byte
change (including a same-inode rewrite) enters the session conflict, cancels autosave, and keeps
the prior proof intact; only an explicit Reload or Keep Mine performs a fresh read and adopts the
accepted observation. Keep Mine resolves against that newest observation rather than retaining a
stale B proof when the file has advanced to C. The rule is identical for anchored and standalone
sessions, including delete/recreate recovery.
A stateful retained A session (pending conflict, detachment, or indeterminate context) also blocks
a replacement-parent B at the same lexical URL until A is resolved; B cannot inherit or clear A's
URL-keyed fence merely by reusing its spelling.

Every coherent retained-file observation made for search-result activation advances that
session's external disk-event generation, even when the observed identity and digest still match.
It therefore supersedes older initial-inspection, Reload, and Keep Mine work before any proof can
be adopted. The same observation is then reconciled before fingerprint/range navigation checks:
an accepted clean version updates the retained proof even if a stale search result is rejected,
while dirty or pending local source records a conflict and keeps its previous proof. A reusable
retired session follows the same rule so rejection cannot strand cleanup behind an unrecorded disk
version. An explicit resolution intent survives or restarts only against a fresh coherent read
under the newer generation; an older asynchronous result cannot finalize the observation or
silently consume the user's choice.

WS3B adds a multi-window convergence fence around that authority arbitration. Choosing Reload or
Keep Mine captures the exact source revision and disk-event generation; input already authorized
before the choice may settle, but any changed revision stale-drops the choice and restores the
prompt without losing accepted source. Initial inspection and explicit-resolution reads run
off-main at the retained location, and a newer watcher event or explicit choice supersedes older
work. Retirement or reactivation advances the session lifecycle and restarts still-valid intent;
obsolete lifecycle, source, event, and request tokens cannot finalize state. Reload application
preparation, exact comparison, hashing, and statistics remain off-main. Save, autosave, writer
eligibility, and native mutation stay fenced until every live exact editor installation accepts the
source snapshot or revokes. Partial convergence therefore cannot publish a mixed model/native state,
and a stale installation cannot clear a newer installation's fence.

`WorkspaceFileSystemLocation.fileURL` is lexical and leaf-state-independent: construction never
inspects the leaf, equal locations expose identical slash-free URLs, and literal relative-path
bytes keep NFC/NFD locations distinct. Session binding/context lookup starts from retained session
identity and stored spelling without standardizing or resolving mutable URLs. Any session write or Save Copy
`committedButIndeterminate` outcome creates a per-session reconciliation quarantine:
a readable Save Copy destination records its observed identity/digest as pending for Reload or Keep
Mine while retaining the prior proof until that explicit resolution; a proven-missing destination
exposes only exact-location `.missing` recovery. Symlink,
non-regular, unreadable, and inspection-failure states remain quarantined with an actionable Check
Again reconciliation that reclassifies only the retained location and authority. The exact
location, URL spelling, result, and prepared digest remain retained even when the leaf becomes a
directory; the location captures its URL once, so a later leaf-kind change cannot append a slash.
That quarantine is independent of dirty state: LRU eviction, editor retirement and metadata
cleanup, missing-file close, workspace close, and workspace switch retain or block rather than
discarding a clean quarantined session. Cmd-S and autosave stay blocked; every
differently spelled or broad Save Copy retry is refused before writer entry, and no legacy URL
fallback is allowed.
Root capture, `relativePath(forFileURL:)`, standalone capture, recovery, and LRU keys preserve
literal UTF-8 path bytes rather than round-tripping through `standardizedFileURL`; only
separator/dot traversal normalization remains. When both canonical and original root spellings
are exact-byte prefixes, relative-path extraction chooses the longest component prefix, so an
original symlink nested under the canonical root is not retained as a false path component.
Non-file URLs and NUL-bearing raw paths are
rejected before any C-string filesystem call. A descriptor-derived canonical parent may unify an
alias cache key, but it does not alter an NFC leaf: an exact missing-source Save Copy reuses that
retained NFC authority/location, while an NFD alternative remains non-exact and is refused.
Durable retained/removal-indeterminate cleanup state is preserved separately from commit status:
App completes the clean/re-home transition, retains the exact authority artifact notice, and
presents a committed-cleanup warning. Proven noncommit remains dirty while preserving its artifact
notice. An explicit acknowledgement API removes the notice and releases its retained authority
lifetime without deleting the artifact; workspace close preserves unacknowledged notices. The
same retained/removal-indeterminate location is included in a committed-but-unadoptable Save Copy's
user-visible reconciliation error, so resolving the document cannot silently strand its artifact.
The
legacy URL facade continues to map typed outcomes for external callers, but App ordinary save and
Save Copy no longer discard those outcomes through that facade.

Workspace retirement transfers the active security-scoped lease only when the retiring session's
retained binding/quarantine authority or captured standalone workspace membership equals the
installed workspace authority; it never reopens or reinspects the current path. Initial and final selected-root proof failures propagate their
typed filesystem error to the normal reload error path. Only actual task/generation cancellation is
silent.

The two activation paths remain deliberately distinct but are both authority-bound. Reload
activation consumes `capture.rootAuthority`, performs its second selected-root proof after the
load, and installs nothing on failure. Workspace-search-result activation consumes the accepted
result's retained `WorkspaceSearchFileAuthority`, activates its exact location/identity, and
checks the installed binding location rather than resolving the result URL. Existing file-tree
sidebar opens and completion reads likewise retain the installed authority; a context-only
quarantined session is treated as authority-bound, so completion cannot derive sibling reads from
replacement B and reload rejects a cross-authority disposition. The last proof does
not prevent a later external namespace race; subsequent anchored operations detect disagreement
and fail closed instead of being described as identity-atomic. Cancellation, fingerprint, exact
range, command, and binding-lifecycle requirements otherwise remain unchanged. Visible sidebar
UI, shortcuts/focus, rendering/accessibility, and general edit/FSEvent search refresh remain
pending.

## 5. Review-Sized Work Packages

### WS1 — MarkdownCore literal search

- [x] Add the public Sendable/Equatable query and match models.
- [x] Implement literal smart/sensitive/insensitive search.
- [x] Implement Unicode-aware whole-word boundaries.
- [x] Produce UTF-16 ranges, one-based lines, and bounded snippets.
- [x] Enforce deterministic non-overlapping ordering and a caller-provided result limit.
- [x] Cover LF, CRLF, CJK, emoji, combining marks, special literal characters, long
  lines, empty/newline queries, and a large synthetic document.
- [x] Record the in-process search architecture in the Decision Log when this direction
  is adopted by implementation.

### WS2 — WorkspaceKit orchestration

- [x] Retain the raw workspace snapshot and generation in AppState.
- [x] Extract shared URL containment logic.
- [x] Add and test the ignore policy.
- [x] Add the async search request/event/summary service.
- [x] Make workspace enumeration cancellation-aware and use generation checks to prevent
  stale enumeration from applying state.
- [x] Overlay unsaved session text over disk content.
- [x] Enforce active read concurrency, byte caps, result caps, cancellation, and
  deterministic aggregation.
- [x] Report skipped and truncated results without failing the whole query.
- [x] Test file deletion races, invalid UTF-8, injected read failures, symlink escapes,
  and rapid cancellation.
- [x] Fingerprint the exact searched UTF-8 content with one stable typed algorithm for disk,
  overlays, and activated sessions.
- [x] Surface unexpected producer failure through a typed terminal state while keeping
  cancellation silent and file-level skips nonfatal.
- [x] Bound ordered-read buffering, instrument buffered/outstanding maxima, and preserve
  path-ordered publication and cancellation cleanup.
- [x] Bound skipped-detail and progress production while preserving exact totals, lossless
  file results, final progress, and terminal state.
- [x] Validate dirty overlays deterministically, rejecting invalid paths, key/path
  mismatches, and normalized collisions before search.
- [x] Keep candidate, overlay, and ignore-ancestor path identity byte-exact so NFC/NFD
  spellings remain independently searchable.

### WS3 — Sidebar and exact navigation

- [x] Own the stream-consuming App Task and explicitly cancel it on query replacement,
  workspace close/switch, and search-state teardown; never rely on loop `break` to stop the
  producer.
- [ ] Add Files/Search sidebar modes without changing the stable `HStack` shell.
- [ ] Add `Command-Shift-F` and search-field focus arbitration.
- [ ] Render grouped partial results with loading, empty, skipped, error, and truncated
  states.
- [ ] Add keyboard and accessibility support.
- [x] Add document-aware, tokenized exact-range navigation in EditorKit.
- [x] Keep tree selection synchronized when a search result opens.
- [x] Validate source fingerprints before applying a result.
- [x] Bind reload, workspace-search-result and file-tree activation, completion reads, and
  session save to the installed filesystem authority without post-install URL resolution.
- [x] Preserve typed write outcomes through App save, including exact-digest expectations,
  descriptor-canonical installed-workspace Save Copy ownership protection, exact cleanup-artifact
  notices, and per-session indeterminate quarantine.
- [ ] Refresh an active search after FSEvents or relevant in-memory document edits.

### WS4 — CI, performance, and acceptance

- [ ] Add MarkdownCore, WorkspaceKit, AppState, and EditorKit regression suites from the
  matrix below.
- [ ] Add a minimal XCUITest target for the actual sidebar shortcut/search/open/reveal
  flow, using a deterministic Debug-only fixture inside the app container rather than
  automating `NSOpenPanel`.
- [ ] Add large-workspace and large-document performance probes.
- [ ] Record measured local performance and choose/freeze budgets from evidence.
- [ ] Update `agent.md`, `docs/acceptance-matrix.md`, and `docs/risk-register.md` only
  after their corresponding gates have evidence.

## 6. CI Validation Matrix

| Target | Hard CI coverage |
|---|---|
| MarkdownCoreTests | Empty/newline queries; literal metacharacters; all case modes; whole word; multiple matches; LF/CRLF; CJK/emoji/combining marks; snippet clipping; UTF-16 ranges; limits; deterministic order; authorized-editor exact no-op and persisted-baseline dirty restoration; saved-baseline rebasing; half-open exact-source reconciliation across surrogate pairs and combining sequences; ambiguous repeated-source alignment rejection |
| WorkspaceKitTests | Candidate filtering; alias/outside-root rejection; byte-distinct NFC/NFD candidates, overlays, ignore rules, tree IDs, completion ordering, and longest root spelling; retained-root no-follow component I/O; immutable result authorities; descriptor identity and exact-digest writes; post-swap rollback/cleanup proofs; invalid UTF-8, unreadable, deletion, same-size/restored-mtime, cancellation, cap, sorting, and terminal-count contracts |
| EditorKitTests | Same-file/cross-file navigation including IME; monotonic cancellation and transition lifetime; contract-free retry; exact installation/writer/base provenance and literal publication equality; shared preflight for command, completion, smart-paste, and image mutations; async image authority before side effects and across placement validation with no untracked rejected-window artifact; post-validation exact context/source fencing and recovery-preserving discard; literal NFC/NFD image-context supersession and commit fencing; selection-only writer bypass; pending composition and half-open stale publication; revision-only synchronization/reacquisition before native mutation; newest-candidate supersession; dismantle cleanup; exact selection/reveal/scroll/focus; stale request rejection; WYSIWYG reveal without mutation |
| PlainsongTests | Debounce/latest-query wins; authority-bound workspace close/switch/reload; transactional result activation with identity/fingerprint/range/hard-link failures preserving prior state; cached/retired physical-ownership collision detachment before stale-inspection eviction; detached observation cancellation propagation; dirty-overlay and clean pending-native activation arbitration before proof adoption; accepted-or-conflicted coherent search observations surviving fingerprint/range rejection and superseding older external work; body-safe exact document-authority caching and fail-closed existing-session cache misses; controlled read-to-adoption parent replacement with the original inode hard-linked into the replacement namespace; retained-parent-lineage rejection after leaf replacement; durable atomic-save and pre-writer Save Copy authority binding through retained destination parents, including committed-but-unadoptable reconciliation with durable cleanup notice retention and visible artifact paths; precommit document, created-asset, and existing-reference component/content validation across move/replacement/hard-link races; workspace-reference authority capture before reads; descriptor-bound discard that durably acquires and fail-closed retains a cleanup racer without a mutable-source restore, reports the separately retained created inode, never attributes a later symlink occupant's path to the acquired racer, distinguishes proven absence from namespace/link inspection failure, refreshes after every successful recovery rename, and never check-then-unlinks a replacement; dirty overlay and completion A/B isolation; exact-path and typed-write recovery/quarantine; session-scoped conflicts; fresh-C Reload/Keep Mine baseline adoption; multi-window installation retirement/reactivation; watcher X-to-Y supersession; native-input and partial-convergence fences; Save Copy during resolution; lifecycle restart; 1 MiB off-main preparation; pending-source and stale-IME arbitration; no-follow substitution races; clean quarantine retention; registration-before-revoke cleanup; stale fingerprint refresh |
| PlainsongUITests | `Command-Shift-F` focuses search; CJK query displays grouped result; activating it opens the correct file and exposes the expected selected range through accessibility |
| PerformanceTests | 2,000-file workspace; 512 KiB admitted file; hosted public `MarkdownEditorView` plus real AppState/source-contract/coordinator/native-view ordinary, re-entrant pair, and multiple marked-text 1 MiB updates with zero App/native activation full-source comparisons; authorized-session exact no-op, same-length edit, and persisted-baseline literal checks; a local hard `<16 ms` gate for both groups; rapid cancellation; result/read byte caps; memory boundedness |

New tests placed in existing SwiftPM, AppTests, and PerformanceTests directories are
already picked up by `make test`. Adding the XCUITest target requires editing `project.yml`
and regenerating the project; never hand-edit the generated `.xcodeproj`.

Strict hosted-runner wall-clock assertions remain subject to risk R15: timing budgets are
hard locally and informational on shared CI, while deterministic file/read/result limits,
cancellation behavior, stale-result rejection, and memory/resource ceilings remain hard
CI gates.

## 7. Definition of Done

- [ ] `make lint`, `make test`, and `make build` pass.
- [ ] No functional acceptance item depends on a manual-only checklist.
- [ ] A newly typed unsaved string appears in workspace search results after debounce.
- [ ] Clicking a result in another file selects the exact UTF-16 match and scrolls it
  into view.
- [ ] Repeating the same result activation works because navigation uses a monotonic ID.
- [ ] Closing or switching workspaces cancels active work and removes old results.
- [ ] A slower old query cannot overwrite a newer query.
- [ ] FSEvents, rename/delete races, and dirty overlays cannot produce an unsafe or stale
  jump.
- [ ] Hidden/ignored entries and symlinks outside the granted root are not read.
- [ ] Truncated and skipped files are visible to the user.
- [ ] Disk I/O and full-text matching do not run on the main actor.
- [ ] Existing file tree, `Command-F`, preview, source-only, and Experimental WYSIWYG
  behavior remain green.

## 8. WS1 Implementation Prompt

Copy the following prompt into a fresh implementation task for the first work package:

```text
You are working in `/Users/davis._.su/Documents/blogeditor`.

Implement the first review-sized change for Phase 3 Workspace Search: the pure
MarkdownCore text-search engine.

Before editing:
1. Read `agent.md` completely.
2. Inspect the current MarkdownCore APIs, UTF-16 `NSRange` conventions, and test style.
3. Run `git status` and preserve all existing user changes. Do not reset, commit, or push.
4. Never edit the generated `.xcodeproj`.

Scope this change strictly to:
- `Packages/MarkdownCore/Sources/MarkdownCore`
- `Packages/MarkdownCore/Tests/MarkdownCoreTests`
- one concise `agent.md` Decision Log entry if needed to record the adopted architecture

Do not modify WorkspaceKit, App, EditorKit, the sidebar, or CI in this change.

Goal:
Add an in-process Swift literal-search core that a later WorkspaceKit search service can
call. Do not launch or depend on an external `rg` executable, and do not add a dependency.

Provide public Sendable and Equatable APIs equivalent to:
- `TextSearchQuery`
  - `pattern: String`
  - case sensitivity with `smart`, `sensitive`, and `insensitive` modes
  - `wholeWord: Bool`
- `TextSearchMatch`
  - the match's UTF-16 `NSRange` in the source
  - a one-based line number
  - bounded preview/snippet text
  - the match's UTF-16 highlight range inside that preview
- `TextSearchEngine.matches(in:query:limit:)`

You may refine the exact names to follow Swift API Design Guidelines, but do not remove
any of those capabilities.

Required semantics:
- This PR implements literal search only. Do not implement regex.
- An empty pattern, a pattern containing a newline, or a non-positive limit returns no
  matches.
- A pattern longer than `TextSearchEngine.maximumPatternUTF16Length` returns no matches;
  the later App layer must surface that named limit as query validation.
- Return non-overlapping matches from left to right.
- Smart case is case-sensitive when the query contains a cased uppercase character and
  case-insensitive otherwise.
- Whole-word mode treats Unicode letters, Unicode numbers, and underscore as word
  characters.
- Handle LF, CRLF, empty lines, and a final line without a newline.
- All source and preview ranges use UTF-16 `NSRange` so they can be passed directly to
  the existing STTextView-based editor.
- Snippet clipping must preserve the complete match, prefer grapheme boundaries, enforce
  the named UTF-16 context cap, and return a valid preview highlight range after
  leading/trailing ellipses are added. If the match occupies only part of a source grapheme
  and reaching that grapheme's boundary would exceed the per-side cap, use the documented
  exact-match boundary fallback on that side instead of an unbounded preview.
- Keep the implementation near O(source length + matches). Do not rescan the complete
  source prefix for every result merely to calculate a line number.
- Keep the API synchronous and pure. MarkdownCore must not create detached tasks or
  import AppKit/SwiftUI.

Tests must cover at least:
1. Basic literal matching across lines and multiple matches on one line.
2. Smart, sensitive, and insensitive case modes.
3. Whole-word and substring matching.
4. CJK, emoji, and combining marks with exact UTF-16 ranges.
5. LF, CRLF, empty lines, and no trailing newline with exact one-based line numbers.
6. Leading and trailing snippet truncation with correct preview highlight ranges.
7. Empty patterns, newline-containing patterns, and zero/negative limits.
8. Regex metacharacters treated as ordinary characters in literal mode.
9. A large synthetic document with a match near the end, guarding against an obvious
   quadratic implementation. Do not depend on repository fixtures because this SwiftPM
   test target does not declare them as resources.

Documentation:
- If the architecture is adopted in this change, add a concise Decision Log entry saying
  that Phase 3 workspace search uses an in-process Swift core instead of an external
  ripgrep process, for App Sandbox compatibility, deterministic CI, and no executable
  dependency.
- Do not claim that Workspace Search is complete; this change is only the MarkdownCore
  matcher.

Verification:
1. `cd Packages/MarkdownCore && swift test`
2. Return to the repository root and run `make lint`
3. Run `make test`
4. Run `git diff --check`

When finished, report:
- files changed;
- the final public API and precise search semantics;
- test and lint results;
- any incomplete requirement or deliberate deviation.

Implement and verify the change now; do not stop after producing another plan.
```
