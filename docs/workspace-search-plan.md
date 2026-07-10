# Phase 3 Workspace Search Plan

> **Status: IN PROGRESS. WS1 and WS2 are implemented and locally verified; WS3–WS4 remain pending.**
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
- Search results from unsaved warm sessions. The App captures immutable text/version
  overlays on the main actor before handing work to WorkspaceKit.
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
- Bounded concurrent file reads: 4.
- Ignore-rule reads are bounded to 128 files and 64 KiB per file (including one extra
  byte used to detect an over-limit file).
- Query debounce in the App: approximately 200 ms.

Reaching a match-count limit is a successful but truncated search, not a fatal error. An
overlong query is a validation state; an oversized file is skipped. The sidebar must show
those states plus counts of unreadable or invalid UTF-8 files instead of presenting any of
them as “no matches.”

## 3. Current Repository Constraints

- `WorkspaceDirectoryScanner.snapshot(root:)` already scans off the main actor and
  classifies workspace entries. The App currently discards its raw snapshot after
  projecting `WorkspaceFileTree`; search needs the raw snapshot and a generation token.
  Its detached enumeration is not currently cancellation-aware, so stale reload work
  must either become cancellable or be rejected by generation before state application.
- The scanner skips hidden entries and package descendants but does not process
  `.gitignore`, `.ignore`, or common generated/vendor directories such as `node_modules`.
- `CompletionWorkspaceProvider` already demonstrates snapshot filtering, security-scoped
  root access, and symlink-resolving containment. Its containment logic should be extracted
  rather than copied a third time.
- `DocumentSession` owns canonical in-memory text, while `AppState.sessionCache` retains up
  to eight warm sessions. WorkspaceKit must receive immutable overlays rather than reading
  main-actor sessions directly.
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
| EditorKit | Apply an exact selection only after the requested document text is installed, then reveal and focus it | `EditorNavigationRequest` or an equivalent editor-owned proxy |

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

- standardized root URL;
- immutable `WorkspaceFileSnapshot`;
- root/workspace generation;
- query and configurable limits;
- dirty overlays keyed by normalized relative path, including a source version or stable
  content fingerprint.

The service should emit partial per-file results and a final summary. Result application
is valid only when root identity, workspace generation, and query generation still match
the active App state.

Search reads must:

- accept only snapshot entries classified as editable Markdown;
- resolve every candidate against the real workspace root;
- reject `..` components and symlinks escaping the root;
- prefer a dirty overlay to disk;
- skip a file that disappears, becomes unreadable, is invalid UTF-8, or exceeds the byte
  cap while continuing other files;
- check cancellation between enumeration, reads, and file-level matching;
- sort published state deterministically even if reads complete out of order.

Start with on-demand reads and instrumentation. Add a bounded actor-owned text cache only
if measured interactive performance requires it; if added, key it by root identity,
entry identity, modification date, and overlay version, with an explicit byte/LRU cap.

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
2. Send a monotonically identified editor navigation request containing the target
   document identity and UTF-16 range. EditorKit applies it only after that document's
   text is installed, sets the selection, scrolls it visible, and focuses the editor.

The result carries a source version/fingerprint. If it no longer matches the activated
session, the App refreshes the active query instead of jumping to a stale offset. In
Experimental WYSIWYG, programmatic selection must reveal the matching source region
without mutating source text.

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
- [x] Enforce read concurrency, byte caps, result caps, cancellation, and deterministic
  aggregation.
- [x] Report skipped and truncated results without failing the whole query.
- [x] Test file deletion races, invalid UTF-8, injected read failures, symlink escapes,
  and rapid cancellation.

### WS3 — Sidebar and exact navigation

- [ ] Add Files/Search sidebar modes without changing the stable `HStack` shell.
- [ ] Add `Command-Shift-F` and search-field focus arbitration.
- [ ] Render grouped partial results with loading, empty, skipped, error, and truncated
  states.
- [ ] Add keyboard and accessibility support.
- [ ] Add document-aware, tokenized exact-range navigation in EditorKit.
- [ ] Keep tree selection synchronized when a search result opens.
- [ ] Validate source fingerprints before applying a result.
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
| WorkspaceKitTests | Markdown candidate filtering; ignore rules; dirty overlay precedence; containment and symlink escape; invalid UTF-8; injected unreadable file; deletion race; oversized files; cancellation; per-file/global caps; stable sorting |
| EditorKitTests | Same-file and cross-file navigation; repeated request IDs; exact selection; reveal/scroll/focus; stale document request ignored; WYSIWYG reveal without mutation |
| PlainsongTests | Debounce; latest-query-wins; workspace close/switch reset; FSEvent refresh; dirty-session refresh; result opens correct node/session; stale fingerprint refresh |
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
