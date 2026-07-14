# Phase 3 Workspace Search Plan

> **Status: IN PROGRESS. WS1, WS2, and WS3A are complete. Draft PR #85 closes the WS3B
> filesystem-authority/write sub-gate. Draft PR #82 remains the headless multi-window lifecycle
> hardening PR and still requires restacking onto that authority baseline; it was not superseded
> by a visible-sidebar branch. Headless WS3B overall, every visible Files/Search sidebar item,
> refresh work, WS3C, WS4, and the overall Definition of Done remain open.**
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
| App | Debounce, task lifecycle, dirty overlays, latest-generation arbitration, sidebar state, FSEvent refresh | `AppState+WorkspaceSearch`, `WorkspaceSearchState` |
| EditorKit | Apply an exact selection only after the requested document text is installed, then reveal and focus it | `EditorNavigationCommand`, `EditorNavigationRequest` |

The future WS3 App lifecycle must retain the `Task` that consumes each event stream and
explicitly cancel that Task before replacing a query, closing or switching a workspace, or
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
- a validated `WorkspaceSearchOverlayCollection` containing canonical relative paths and
  immutable unsaved text.

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

Dirty overlays are validated before a request is built. `WorkspaceSearchOverlay` rejects
empty, absolute, and traversing paths and stores a canonical workspace-relative path.
`WorkspaceSearchOverlayCollection` rejects dictionary key/path mismatches and rejects every
normalized collision instead of choosing a winner by input or dictionary iteration order;
for example, `post.md` and `./post.md` cannot coexist. Valid canonical overlays continue to
take precedence over disk content. An anchored dirty session is eligible only when its retained
root authority equals the installed authority used for the request; moving root A and placing B
at the old spelling cannot inject a cached A session's dirty text into B's search.

Workspace document identity keeps one physical-target policy. Initial in-root aliases are
resolved and containment-checked during candidate planning, then expressed as one canonical
lexical root-relative path; aliases to the same target collapse to that candidate, and an
outside-root target remains a typed `symlinkEscape`. Once the canonical path is bound to the
request's captured root authority, production reads never resolve the alias or another mutable
URL again. Every component is opened no-follow through retained descriptors, so a symlink,
rename, or replacement introduced after planning fails closed. Dirty overlays use the same
canonical candidate key and are accepted only after the exact physical leaf is validated.
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
components. This is deliberately not complete Git ignore compatibility: bracket classes,
backslash escaping, global/exclude files, and Git's traversal rule that prevents a child from
being re-included beneath an ignored parent are unsupported. Because WS2 filters an immutable
snapshot rather than pruning a filesystem walk, a later negation may re-include a child.

### 4.4 App and editor navigation

The sidebar gains two modes inside the existing stable shell:

- **Files** preserves the current tree, file information, and frontmatter panel.
- **Search** presents the field, case/word controls, progress, grouped results, and
  summary/error states.

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
is not the retained result/match is ignored without disturbing unrelated navigation. Once an
active retained result and match are accepted as a new intent, App emits a newer cancellation
before resolving a node, opening a file, checking document identity or fingerprint, or
validating the final UTF-16 range. Success emits an even newer navigation. Missing nodes,
open/detach/identity failures, fingerprint mismatch, and invalid ranges leave the cancellation
as the latest command, so an older pending navigation cannot execute afterward.
Destination lookup/readability and cached-session identity are validated before committing a
document switch. A missing or unreadable destination therefore leaves the current document's
autosave, statistics, completion work, prompts, and editor state intact. Reactivating the
already-current session is a document-transition no-op; successful result navigation still
uses the newer exact-range command.

The result carries the exact searched-content fingerprint. If fingerprinting the activated
session's current text does not produce the same digest and UTF-8 byte count, the App
refreshes the active query instead of jumping to a stale offset. A document/session version
may still arbitrate lifecycle elsewhere, but it is never proof of content equality. In
Experimental WYSIWYG, programmatic selection must reveal the matching source region without
mutating source text.

**Implemented WS3A subset.** EditorKit now accepts an optional opaque document identity and
a monotonic `EditorNavigationCommand` carrying either an `EditorNavigationRequest` or a
cancellation ID. A newer command supersedes older pending work; cancellation clears pending
navigation and coordinator retry/deferral tasks, while older and repeated commands are idempotently
ignored. Per-update candidate generations, not optional-identity equality, keep the installed
model bindings pinned through IME composition and replace the binding, identity, and installed
generation together only after the candidate's literal UTF-16 text is present. Exact raw
UTF-16 selection, scrolling, and focus occur only for that installed candidate after IME has
ended and the editor is window-attached. Invalid ranges are rejected without clamping. At
the WS3A landing point, App ownership, fingerprint arbitration, sidebar behavior, tree
synchronization, shortcuts, and refresh lifecycle remained pending WS3 work; WS3B advances
only the headless App subset below and remains open at this landing point.

**Implemented WS3B lifecycle foundation (gate still open).** MarkdownCore exposes one
allocation-free exact UTF-16 source
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

The App/editor bridge also carries an opaque binding ID distinct from optional navigation
identity. EditorKit reports installation only from a successful `finishDocumentTransition`
after marked text ends and exact candidate source is live, does not transfer during prepare,
and revokes on dismantle. If workspace/file retirement occurs first, App transfers only that
exact binding's session, registration, session-specific autosave/statistics work, and old
security-scoped authority into a binding-ID-keyed retirement. Unrelated sessions close
normally. The old authority is released only after the binding is replaced or revoked and its
latest source has been saved; an unresolved external conflict or save failure keeps the exact
session recoverable instead of discarding it. App generic writes remain current-session-only.
The installed binding may commit to its exact non-current active or retired session only while
the registration and lease both match. Such a commit updates that session's raw source,
version, and dirty state once without touching the current document's text or tasks.

External-change conflicts are session-scoped by the canonical URL entry in
`pendingExternalTexts`, not by whichever banner is currently visible. Autosave and explicit
`save(session:)` reject that exact session even while another document is current. LRU
eviction, workspace retirement, and close paths retain or block on the dirty conflict rather
than overwriting disk or silently dropping the session. Reload restores the external text as
clean; Keep Mine clears the conflict and restores save/autosave eligibility. Binding
registration cleanup is exact and idempotent: retired, evicted, and closed sessions lose their
registration, while a matching revoke can still clear the installed lease after registration
cleanup; unrelated or stale revokes cannot clear a newer lease.

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

`WorkspaceFileSystemLocation.fileURL` is lexical and leaf-state-independent: construction never
inspects the leaf, equal locations expose identical slash-free URLs, and literal relative-path
bytes keep NFC/NFD locations distinct. Session binding/context lookup starts from retained session
identity and stored spelling without standardizing or resolving mutable URLs. Any session write or Save Copy
`committedButIndeterminate` outcome creates a per-session reconciliation quarantine:
a readable Save Copy destination is re-homed with observed identity/digest for Reload or Keep Mine,
while a proven-missing destination exposes only exact-location `.missing` recovery. Symlink,
non-regular, unreadable, and inspection-failure states remain quarantined with an actionable Check
Again reconciliation that reclassifies only the retained location and authority. The exact
location, URL spelling, result, and prepared digest remain retained even when the leaf becomes a
directory; the location captures its URL once, so a later leaf-kind change cannot append a slash.
That quarantine is independent of dirty state: LRU eviction, editor retirement and metadata
cleanup, missing-file close, workspace close, and workspace switch retain or block rather than
discarding a clean quarantined session. Cmd-S and autosave stay blocked; every
differently spelled or broad Save Copy retry is refused before writer entry, and no legacy URL
fallback is allowed.
Durable retained/removal-indeterminate cleanup state is preserved separately from commit status:
App completes the clean/re-home transition, retains the exact authority artifact notice, and
presents a committed-cleanup warning. Proven noncommit remains dirty while preserving its artifact
notice. An explicit acknowledgement API removes the notice and releases its retained authority
lifetime without deleting the artifact; workspace close preserves unacknowledged notices. The
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
| MarkdownCoreTests | Empty/newline queries; literal metacharacters; all case modes; whole word; multiple matches; LF/CRLF; CJK/emoji/combining marks; snippet clipping; UTF-16 ranges; limits; deterministic order |
| WorkspaceKitTests | Markdown candidate filtering before and after initial alias canonicalization; alias deduplication and outside-root rejection; no-follow root/intermediate/leaf substitution rejection after authority binding; immutable authority and descriptor identity; A/B completion-read separation; terminal destination proof after every cleanup-to-`notCommitted` path; tri-state cleanup inspection; write-only/no-access cleanup; ignore rules; dirty overlay precedence; invalid UTF-8; injected unreadable file; deletion race; oversized files; actual Task cancellation versus reader-thrown `CancellationError`; per-file/global caps; post-cap accounting; stable sorting and internally consistent terminal counts |
| EditorKitTests | Same-file and cross-file navigation, including nil identities during IME; monotonic navigation/cancellation IDs and task cleanup; exact selection; reveal/scroll/focus; stale document request ignored; WYSIWYG reveal without mutation |
| PlainsongTests | Debounce; latest-query-wins; workspace close/switch reset, including a real anchored A session switching to unrelated B; FSEvent refresh; cached-current reconciliation from loaded activation bytes; typed initial/final root-proof failures; final-suspension selection preservation and cached-source re-arbitration; independently exercised cached/retired same-spelling authority-mismatch refusal; stale-A dirty-overlay exclusion and current-document-only completion for binding- and context-only sessions after B replaces A's spelling; missing-current autosave suppression; exact BOM digest save; session-scoped external conflicts; unanchored ordinary-save replacement-inode/content-digest/unavailable-proof refusal; exact-location indeterminate-write quarantine with readable Reload/Keep Mine, proven-missing literal-spelling retry, actionable invalid-state reconciliation, and differently spelled retry refusal; clean quarantine retention through LRU, editor retirement/cleanup, missing close, workspace close, and switch; authority-exact original-path anchored/unanchored recovery; A-to-B same-spelling, NFC/NFD, and cross-authority cached/retired/editor/context ownership refusal; exact-inspection Save Copy create/replacement races; outside-leaf symlink refusal; descriptor-physical ownership across cached/retired/editor-bound/unanchored sessions; lexical directory-leaf and stable-state-URL behavior; unlinked/replaced retirement from captured membership; durable/noncommit cleanup-artifact notice acknowledgement across workspace close; binding-ID retirement authority after selected-root retarget; registration-before-revoke cleanup; symlink alias session reuse; result opens exact authority location; post-activation A/B rejection; activation task preservation; accepted-failure cancellation; stale fingerprint refresh |
| PlainsongUITests | `Command-Shift-F` focuses search; CJK query displays grouped result; activating it opens the correct file and exposes the expected selected range through accessibility |
| PerformanceTests | 2,000-file workspace; 512 KiB admitted file plus a 1 MiB MarkdownCore stress probe; rapid cancellation; result/read byte caps; memory boundedness |

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
