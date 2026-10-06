# In-Document Replace — Gate Specification

> **Status: spec is on `main`; this file now tracks implementation evidence.**
> The successor to in-document Find (PR #95/#96/#97). **R0 is GO on Candidate B1
> (minimal enclosing range)** per the hosted writer-undo spike on
> `phase3-editor-replace-r0` (PR #112): Candidate A is one native undo group but
> publishes once per match, so it is NO-GO for Replace All; Candidate B2 works as a
> fallback and is not chosen while B1 preserves source, undo, dirty, and presentation.
> The spike does not ship user-facing Replace. **PR C (`phase3-editor-replace-model`) is the pure MarkdownCore
> planner:** it closes R1 and the R3 *model* bullets with named tests, adds
> `EditorFindSession.withUnresolvedCurrent` for post-replace `0 / total`, and
> binds every continuation rescan to the originating session query. Cancellation
> cadence remains independent from the at-most-100 visible progress milestones,
> and malformed public UTF-16 ranges fail closed without end overflow. The pure
> B1 slice builder validates and rebases absolute ranges; mapped batch caret,
> session anchor, and collapsed selection share one post-write clamp. PR C
> introduces no mutation, UI, STTextView type, dependency, or `project.yml` change.
> **PR D (`phase3-editor-replace-single`) is the source-only single Replace:** it
> closes R2 and the R3 publication/writer/literal-identical integration bullets.
> The executor arms Find for its own native write; a publication that reaches
> Find during the write is recorded, not scheduled as `.edit`, and no Find
> observer runs inside the writer-authorized closure. The outcome comes from the
> observed post-write snapshot: exactly the planned source at a newer revision is
> admitted once as `EditorFindScheduleReason.replacement`, without the typing
> debounce; an unchanged snapshot is `writeNotApplied`, and any other change is
> an `unverifiedWrite` recomputed as an ordinary edit. Experimental WYSIWYG is a
> typed zero-effect refusal (`wysiwygPresentationInstalled`) while fold or image
> presentation is installed; PR F lifts it. R6 marked-text coverage here is the
> deterministic editor refusal only.
> **PR E (`phase3-editor-replace-authorization`) is App authorization and
> lifecycle fences:** it closes R7. App owns `EditorReplaceAuthorizationDecision`,
> one refusal per §5.6 state (never `canSave`; an installed untitled session is
> allowed), checked at command validation and again by EditorKit at commit, in the
> writer's synchronous turn. It is stricter than §5.6 in one place: an in-flight
> disk inspection refuses (`externalObservationPending`), so each autosave's own
> file event opens a brief refusal window. Plans carry a monotonic App authority
> generation plus the session revision. The generation advances when a fence or
> prompt map the decision reads, or an editor installation, is set or cleared, and
> on rebind, reload, rekey, focus, key-window, and bar transitions.
> `sessionStateURL`'s inputs and `externalResolutionIntentCaptures` are not
> hooked; the rekey notification, the write-fence `didSet`, and the live
> evaluation at commit cover them. An EditorKit editor stamp adds key window,
> installation, source revision, and selection, compared by value.
> `EditorReplaceCommandDispatcher` routes a plain command only to the installed
> editor of the key window: its responder chain, or App's find-chrome/query-field
> fallback exactly where Find uses it. Reload / Keep Mine completion supersedes
> every plan and recounts Find counter-only. A write that is not applied
> (`.refused(.writeNotApplied)`) now leaves no undo step. There is still no product
> UI; the PR G Replace All pipeline is implemented behind plain command seams,
> R4/R5 now have PR G product evidence; R6 and R8–R10 stay open.
> The controller split keeps
> `EditorFindController.swift` to 400 lines, with private task/fence ownership in
> `EditorFindMatchWorker.swift` (127 lines after PR G), private step intent ownership in
> `EditorFindStepIntentState.swift` (114 lines), and the unchanged top-level types in
> `EditorFindDocumentBinding.swift` (17 lines) and `EditorFindScheduleReason.swift`
> (21 lines). Private state and helpers retain private access; no gate changes.
> **PR F (`phase3-editor-replace-wysiwyg`) implements Experimental WYSIWYG
> single Replace:** it closes R5 bullets 1–4 and 6. When the current match is not
> the selection, the action only selects the raw match and synchronously removes
> any image marker over it; folded owners reveal later through the existing
> debounced selection-driven reparse. An action whose selection already is the
> match (even the first, e.g. after Find selected it) commits only with an applied
> model at the current installation/revision, an exact raw slice, every overlapping
> owner revealed, no folded attribute over the match or those owners' own fold
> chrome (for a link, `[` plus the whole `](url "title")`), and no image marker
> over the match or an overlapping image source. A construct nested in a revealed
> owner but untouched by the match keeps its fold (review fix: requiring the
> owner's whole range unfolded refused such matches forever). Otherwise the action
> refuses with `wysiwygRangeNotRevealed`, without revealing or writing; the unused
> `wysiwygPresentationInstalled` case is removed. Post-write and native Undo/Redo
> reparse `text` through the existing off-main highlighter and
> the 20 ms debounce from the highlight-scheduling bug-fix PR
> (`EditorHighlightScheduler`).
> Native input, the editing/marked-text apply guards, and
> selection-driven reveal are unchanged; the only edit-path addition is an O(1)
> record of each applied highlight. App authorization, writer activation, and
> replacement publication retain PR D/E's path. PR G supplies the remaining
> R5 batch evidence below; R6 and R9 stay open.
> **PR G (`phase3-editor-replace-all`, review fixes) adds the product
> Candidate B1 Replace All pipeline.** MarkdownCore builds the exact minimal
> enclosing slice off-main with checked UTF-16 growth, bounded cancellation and
> bounded progress. EditorKit commits it through one writer activation/native
> insertion, records one replacement-aware publication, and restores the mapped
> selection through native Undo/Redo. App owns the action/lifecycle tuple,
> selection observation, marked-text owner seam, and final synchronous recheck.
> The R0 spike remains as hosted mechanism evidence with its enum renamed
> `EditorReplaceBatchSpikePlan`; product tests use a separate executor. The
> batch WYSIWYG path clears fold/image attributes once and relies on the normal
> authoritative reparse; failed writes reset caches and request a fresh derivation.
> Full MarkdownCore 320 tests, full EditorKit 428 tests (seven opt-in skips),
> and the selected hosted Find/Replace/R0 plus nine WYSIWYG policy tests
> (163 tests, three opt-in skips) pass with zero failures.
> R4 and R5 close, with product evidence for the Replace All portions of R2/R3.
> R6, R8, R9 and R10 remain open; PR H owns user-facing controls/messages.
> Build, pinned lint and diff checks pass. See
> [initial PR G verification](evidence/editor-replace-g-20261005.json) and
> [review-fix verification](evidence/editor-replace-g-review-fixes-20261005.json).
> **PR H (`phase3-editor-replace-ui`) is the product UI:** the Find row is the
> first row of a compact stack; a native disclosure reveals an owned AppKit
> replacement `NSTextField`, owned AppKit Replace / Replace All / Cancel buttons,
> and owned AppKit labels for progress, results, blocked reasons, overflow and
> field errors. Edit gains Find and Replace…, Replace and Replace All with no
> shortcut. The replacement field is the third marked-text owner: single Replace,
> Replace All entry and the final pre-commit recheck refuse while any owner
> composes, with one `.markedText` result. Collapse is the real authority seam,
> and any authority advance or query/option edit stops a preparing plan at once.
> R8 and R6 deterministic bullets 1–4 close; R6's owner Zhuyin/Pinyin bullets,
> the physical Full Keyboard Access smoke (new R8 owner bullet), R9 and R10 stay
> open. See [PR H verification](evidence/editor-replace-h-20261006.json).
>
> Check a gate only with named-test or owner-recorded evidence in the same
> implementation commit.

Created 2026-07-29 as the current-document Replace gate set. See `agent.md`
§6.1 (STTextView abstraction), §6.4 (shortcuts), §12 (performance), §13
(WYSIWYG source canonicality), §17 (layering / collaboration), the 2026-07-27
in-document Find Decision Log rows, `docs/editor-find-gates.md`, and
`docs/workspace-search-plan.md` §2.2.

## 1. Outcome

Ship literal replacement in the current editor document without creating a
second search language or bypassing document authority:

- Extend the existing Find bar with a disclosed replacement row; do not create
  a second panel.
- Replace the exact active match and advance to the next retained match in the
  authoritative post-write session.
- Replace All uses one exact, non-truncated pre-write match snapshot; any
  source-changing batch is exactly one native undo step.
- Matching remains the existing pure `TextSearchEngine` plus
  `EditorFindSession`; replacement planning consumes those exact non-overlapping
  UTF-16 ranges.
- Every source mutation enters through the WS3B writer-activation path in
  `MarkdownTextViewCoordinator+WriterActivation.swift`.
- Replacement is refused while IME marked text or any write/reconciliation
  fence exists. A refused action is never queued for later.
- Experimental WYSIWYG mutates only raw backing-source ranges. Folded
  delimiters, link destinations, and image projection are presentation, never
  replacement storage.
- Workspace-wide replace remains deferred. This document covers the current
  Markdown/MDX document only.

## 2. Baseline and prerequisites (code verified)

| Observation | Consequence for Replace |
|---|---|
| `TextSearchEngine.matches` returns ordered, non-overlapping literal matches as UTF-16 `NSRange`s. Foundation case folding / canonical equivalence may make a match length differ from the query length. | Replacement consumes returned ranges; it must never assume `match.length == query.utf16.count`, rematch with another API, or patch ranges using query length. |
| `EditorFindSession.search` always calls `TextSearchEngine` with `EditorFindLimits.engineMatchLimit` (10,001), retains at most 10,000 matches, and records truncation. | Replace and Replace All reuse the same query/options/session. A second matcher or replacement-only scan is forbidden. |
| `EditorFindController` debounces matching off-main and fences apply by document identity, source revision, and query generation. Ordinary edit recompute preserves the old ordinal when possible. | Replace needs an explicit post-write recompute reason and continuation anchor; treating replacement as an ordinary edit gives the wrong ordinal when lengths or boundaries change. |
| A non-empty `EditorFindSession` currently resolves a current ordinal immediately, while `EditorFindUIState` can already present `0 / total`. | The pure model PR must add an explicit post-replace “matches exist, no current match” state/capability. This is ordinal state, not a change to `TextSearchEngine` semantics. |
| Authorized native publication currently flows through App document editing and immediately notifies Find as an ordinary `.edit`. | Replace must add one replacement-aware publication/recompute handoff that consumes that revision once. It may not race an ordinary ordinal-preserving scan with a second continuation-aware scan. |
| `performPreflightedTextMutation` authorizes one synchronous closure after writer activation. Re-entrant native edits are accepted only for the authorized coordinator and text view. | A replacement plan must be complete before entering the closure. No `await`, progress yield, or cancellable pause may occur during commit. |
| Writer preflight may synchronize a stale native view to authoritative App source, clamp selection, and still refuse the requested event. | Zero-effect refusal is required for App replacement-authorization fences before preflight. A stale writer may perform existing authoritative convergence, but it opens no replacement undo group, applies no replacement, and forces counter-only recompute before retry. |
| Existing programmatic replacements use native `STTextView.insertText`, which re-enters the coordinator and publishes source. Multiple low-level inserts can share one activation, but each still publishes. | Source inspection does not prove that a 10,000-match batch is one coherent undo/publication. R0 must compare candidate batch mechanisms. |
| Writer activation currently fences active/deferred external-resolution work, but it does not by itself cover every unresolved external prompt or `indeterminateSessionWrites` quarantine that blocks save/autosave. | Writer activation is necessary but not sufficient for Replace. App must provide a replacement-specific, commit-time authorization decision in addition to the WS3B preflight (R7). |
| The existing Find bar owns an AppKit query field, case/whole-word controls, counter, next/previous, and App-owned key-window focus receipts. | Replace extends that bar and its focus domain. It does not introduce a global panel or reuse workspace-search focus tokens. |
| `⌥⌘F` is already the locked Format Table shortcut (`agent.md` §6.4). | v1 adds no global Replace shortcut and does not steal `⌥⌘F`. |
| The in-flight Find follow-up owns highlight-all, XCUITest, and the Find latency budget. | Replace implementation PRs wait for it to merge and extend its production surfaces rather than racing or duplicating them. |

## 3. Fixed engine, authority, and scope decisions

### 3.1 Matching semantics

**Choice:** current-document Replace uses the exact
`TextSearchQuery` + `TextSearchEngine` + `EditorFindSession` already used by
Find. The session's exact current match or exact non-truncated retained set is
the only replacement input.

**Why:**

1. Find and Replace must agree on smart/sensitive/insensitive case, Unicode
   whole-word boundaries, canonical-equivalent match lengths, pattern
   validation, non-overlap, UTF-16 ranges, and the 10,000 retained ceiling.
2. A second matcher could replace text that Find did not show, or show text that
   Replace cannot safely mutate.
3. Existing document identity, source revision, query generation, and exact
   navigation fences remain reusable.

**Rejected:**

- `NSTextFinder` / `STTextFinderClient` matching or mutation.
- Re-running `String`/`NSString` matching inside a replacement executor.
- Regex, capture groups, or a new template parser in v1.

Replacement text is literal. `$1`, `\1`, and `\n` have no expansion semantics;
if accepted by the field they are ordinary characters. v1's compact
replacement field is single-line, so a value containing a literal line break
is rejected by validation rather than interpreted as an escape sequence.
`EditorReplaceLimits.maximumReplacementUTF16Length` is a separate named v1
default of **256 UTF-16 code units**. It deliberately matches the current query
field scale without changing `TextSearchEngine.maximumPatternUTF16Length`.
The default, plus the existing match ceiling, bounds worst-case batch growth;
empty replacement remains valid. Unbounded replacement was rejected because
10,000 matches alone permits multi-gigabyte growth. A total-document cap was
rejected because it would make an already-open large document ineligible even
for a shrinking replacement. The owner may change 256 before pure-model PR C,
but only through a Decision Log update with a named measured bound; §10 records
that policy choice.

### 3.2 Mutation authority

**Choice:** every source-changing Replace action must enter through
`MarkdownTextViewCoordinator.performPreflightedTextMutation` (or a narrowly
named successor in the same WS3B writer-activation family) and perform native
STTextView insertion inside its synchronous authorized closure.

The App may decide whether replacement is currently allowed, but App never
receives an STTextView type or mutates text. EditorKit remains the only layer
that knows the concrete editor.

**Rejected:**

- `STTextFinderClient.replaceCharacters`.
- Direct character writes through `textStorage`.
- Assigning App/SwiftUI document bindings as a replacement mechanism.
- One independent writer preflight per match.
- Holding writer authority across an `await`.

Attribute-only highlight/presentation writes are not precedent for character
mutation: those paths deliberately disable undo and preserve the backing
string.

### 3.3 Replace All undo decision

**Choice:** a source-changing Replace All is one undo step for the whole batch
(an all-literal-identical no-op creates none, §5.2). Per-match undo is rejected
because a user must be able to reverse one destructive command atomically, and
10,000 undo operations would make partial rollback the normal failure mode.

Writer activation currently authorizes a synchronous closure; it does **not**
promise undo grouping or one publication. Therefore this choice is conditional
on R0's mechanism proof:

| R0 outcome | Consequence |
|---|---|
| A candidate produces one writer-authorized, all-or-none native change; one Undo restores the exact source/selection/dirty state; one Redo reapplies it; prior undo history remains separate; publication and performance are acceptable. | Replace All may proceed using only that proven candidate. |
| A candidate is one undo step but publishes an intermediate source per match, merges with prior typing, exposes partial state, or fails the 1 MiB path. | Candidate is NO-GO; try the next allowed R0 candidate. |
| No allowed candidate passes. | Replace All is infeasible as specified. Keep it deferred or change the product design in a new Decision Log entry; do not silently ship per-match undo. |

R0 compares:

1. **Candidate A:** one writer activation plus `breakUndoCoalescing()`, a
   caller-owned outer undo group, and reverse-ordered replacements through the
   authorized native edit helper.
2. **Candidate B1:** build the exact final text off-main, then replace the
   minimal enclosing raw source range once inside one writer activation.
3. **Candidate B2 fallback:** only if B1 cannot preserve native
   STTextView/selection behavior, build the final text off-main and replace the
   full document once inside one writer activation.

Candidate A may group undo while still publishing N intermediate sources. B1
avoids gratuitously replacing untouched prefix/suffix; B2 must be evaluated
separately because a full-document native edit has different selection,
attribute, and WYSIWYG consequences. A one-insert candidate is preferred only
if it preserves selection, publication, latency, and presentation; that is a
hypothesis until R0 passes.

### 3.4 Current-document boundary

This gate covers the currently installed Markdown/MDX document only.
`docs/workspace-search-plan.md` §2.2 continues to defer workspace-wide replace.
No file enumeration, dirty-overlay fan-out, filesystem transaction, or
multi-document undo is introduced here.

App/ and MarkdownCore/ must not import STTextView types (`agent.md` §6.1).
Regex remains a separate gate because the current engine is literal-only and
not synchronously cancel-safe for pathological regex work.

## 4. Layering (`agent.md` §17 is law)

```text
App
  replace-row state, menu items, focus arbitration, progress presentation,
  current-session replacement authorization and lifecycle fences
    ↓ plain values / capabilities only
EditorKit
  responder delivery, exact installed-selection proof, writer activation,
  native mutation, undo boundary, WYSIWYG reveal/reapply
    ↓
MarkdownCore
  pure replacement plan over TextSearchEngine / EditorFindSession matches,
  post-write continuation-anchor and ordinal rules
```

- MarkdownCore imports no AppKit, SwiftUI, EditorKit, WorkspaceKit, or
  STTextView.
- EditorKit imports neither App nor WorkspaceKit.
- App composes plain EditorKit commands/capabilities and never names a concrete
  STTextView selector.
- WorkspaceKit has no role in current-document replacement.
- No new Swift or npm dependencies.
- Any future target/scheme change goes through `project.yml`, never a generated
  `.xcodeproj`.

## 5. Product contract (v1)

### 5.1 Existing bar, fields, menu items, and shortcuts

The existing Find HStack becomes the first row of a compact `VStack`. A
disclosure reveals a second row with:

- one owned AppKit single-line replacement `NSTextField`;
- **Replace**;
- **Replace All**;
- a progress/status label and explicit **Cancel** while a Replace All plan is
  being prepared.

Empty replacement is valid (delete the matched text). Replacement values are
literal and retain their spelling. v1 does not expose escape expansion or
multiline replacement. More than 256 UTF-16 code units is invalid with an
explicit field error and disables both replacement actions.

| Command / control | v1 behavior |
|---|---|
| Existing `⌘F` / Find… | Show/re-focus the bar, focus the query field, and select the query, as today. It never collapses an already-expanded replacement row; a new query-focus intent cancels any pre-commit Replace All plan. |
| **Find and Replace…** menu item | Show/expand the existing bar and use the existing query-focus + select-all intent, cancelling any older pre-commit plan. Query is first; Tab/click reaches replacement. **No global shortcut** in v1 because `⌥⌘F` remains Format Table. |
| Existing `⌘G` / `⇧⌘G` | Unchanged Find Next / Previous. They never mutate. |
| Existing `⌘E` | Set the query from the applied editor selection only. It does not show, expand, collapse, or focus the bar; it does not clear or change replacement text. |
| **Replace** button/menu item | Replace the exact applied current match, then rescan authoritative post-write source and advance without implicit wrap (§5.2). No new global shortcut. Return in the replacement field invokes this action only when no marked text exists. |
| **Replace All** button/menu item | Prepare and commit the exact non-truncated match snapshot once (§5.3). No new global shortcut. |
| Cancel during planning | Cancel the pre-commit plan with zero source/undo/ordinal effect and keep the expanded bar available. Closing the bar also cancels planning. |
| Escape | Marked text gets first refusal. Otherwise it closes the bar and cancels any pre-commit plan, matching the existing find-bar discipline. |
| `⇧⌘F` | Supersede the pending editor-find focus intent, cancel any pre-commit Replace All plan, and focus workspace search. It neither consumes editor-find receipts nor clears query/replacement text or expansion state. |

There is no separate v1 “Replace without advancing” command. That alternative
adds an ambiguous current ordinal after the old match disappears and makes
repeated replacement require an extra Find Next. The Replace action therefore
has the ordinary compact-bar behavior: replace the current match and advance.

Menu replacement actions use the same key-window responder eligibility as
Find. Bar buttons may call the App intent directly, as existing
Previous/Next/Done buttons do. A menu or button must still reach the exact
installed editor for that key window; it may not fall back to another window.
The owned query/replacement field editors count as provenance for that key
window, so a menu action may be invoked while either field is focused.

**Replace** and **Replace All** are eligible only while the bar is visible and
the replacement row is expanded. Closing or collapsing the row cancels
pre-commit work and makes both destructive menu commands ineligible even
though current-document field values may be retained. **Find and Replace…**
remains eligible to show/expand the bar. Hidden retained replacement text can
never execute.

The replacement row adds stable accessibility identifiers under
`plainsong.editorFind.*` for disclosure, replacement field, Replace,
Replace All, progress, Cancel, blocked reason, and overflow state.

Replacement chrome follows the existing Find lifecycle:

| Transition | Query / replacement / expansion / progress |
|---|---|
| Escape / Done | Close the bar and cancel pre-commit work; retain query, replacement value, and expanded/collapsed choice for the current document. |
| Collapse replacement row | Keep the bar/query visible and retain replacement value; cancel pre-commit work and make Replace/Replace All menu actions ineligible. |
| Sidebar file switch or workspace-search activation to another document | Keep the visible/expanded bar and both field values; cancel progress, clear old match/current state, and rebind/recompute counter-only for the new document. No replacement intent survives. |
| External Reload / Keep Mine resolution or same-session rekey | Retain both field values and expansion; cancel progress; enable only after authoritative post-resolution recompute. |
| No document | Close/collapse and cancel progress; retain query/replacement values as current workspace UI memory, but clear the session/current state. Supersede pending focus and clear per-window focus reports; never reset monotonic receipt high-water marks. A later document requires an explicit Find/Find and Replace action. |
| Workspace close or workspace switch | Close/collapse and cancel progress; clear query, replacement value, session/current state, and per-window focus reports. Supersede pending focus while retaining monotonic receipt high-water marks so a stale remount cannot replay an old token. |

### 5.2 Exact match, recompute, and current ordinal

#### Before one replacement

Replace is eligible only when all of these describe the same current source:

1. controller document identity, revision, and query generation;
2. exact `EditorFindSession.currentMatch`;
3. the editor's **applied** selection provenance (installed identity, source
   revision, installed state) and exact UTF-16 range;
4. replacement authorization and, for a source-changing action, writer
   activation (§5.6).

If the applied selection does not yet equal the current match, the first action
issues the existing exact navigation/reveal and performs **no mutation**. It
does not queue a replacement to fire after focus, presentation, or lifecycle
state changes.

#### After one successful replacement

Let the pre-write current match be `[start, end)` and let `L` be the
replacement's UTF-16 length.

1. Publish the authoritative post-write text/revision through the existing
   native writer path.
2. Set `resumeUTF16 = start + L` in that post-write source.
3. Re-run the whole raw source once through the same `TextSearchEngine` and
   query/options. Do not delta-patch old ranges or preserve the old ordinal.
4. The new current match is the first retained recomputed match whose start is
   `>= resumeUTF16`; its new array position is the new 1-based ordinal. Emit
   the existing non-focus-stealing exact navigation to that match.
5. If there is no such retained match, current is `nil` and the counter may
   present `0 / total`; leave a collapsed editor selection at `resumeUTF16`.
   Store that same value as `caretAnchorUTF16`. Do **not** wrap automatically.
   An explicit Next/`⌘G` performs the existing retained-set anchor/wrap.

The native source publication and controller invalidation are one logical
handoff. The authoritative post-write revision must be consumed by an explicit
replacement schedule reason carrying `resumeUTF16` (or equivalent plain
outcome), instead of first scheduling the existing ordinary `.edit` reason.
Named coverage must prove one engine invocation applies for that revision,
that the ordinary ordinal-preserving result cannot win a race, and that other
document-text consumers still receive their normal publication.

This rule gives forward progress when replacement contains the search pattern.
For example, replacing `a` with `aa` counts/highlights the inserted `a`
matches after the rescan, but the automatic continuation skips matches that
begin inside the inserted `[start, start + L)` span. They remain reachable
after an explicit wrap. Replacement-created matches crossing a boundary are
also determined only by the full rescan.

Single Replace remains allowed when the session is truncated because its exact
current match is retained and applied. Post-write continuation considers only
the recomputed `EditorFindSession.matches` retained prefix, exactly like Find
Next/Previous; it never starts a second scan past the ceiling. If no retained
match starts at/after `resumeUTF16` (including after replacing the 10,000th
retained match), current becomes `nil`, the counter remains distinctly
truncated (for example `0 / 10000+`), and explicit Next wraps within the
retained prefix.

Literal-identical replacement is decided by comparing the exact matched raw
UTF-16 code-unit sequence with the replacement code units. Swift `String ==`
is not the test because canonically equivalent but differently encoded source
is a real edit. For a literally identical single match, apply all ordinary
eligibility, marked-text, and fence checks, then skip writer activation,
revision, undo, and rescan. Advance within the unchanged retained session to
the first match starting at/after the current match end, without implicit wrap;
if none exists, collapse selection at the old match end, store that value as
`caretAnchorUTF16`, and make current `nil`. This is an ordinal/navigation
action, not a source mutation.

#### After Replace All

- The pre-write exact snapshot is consumed once, in its original
  non-overlapping range order; execution may apply ranges in reverse or build
  one final source, depending on R0.
- Inserted replacement text is never recursively rematched and replaced inside
  the same command.
- After the one batch commit, rescan the whole authoritative post-write source
  once with the same engine/query/options.
- Set current to `nil` regardless of remaining matches. The counter reports
  the recomputed total. Preserve the mapped collapsed selection as the
  session's `caretAnchorUTF16`; explicit Next/Previous then use the existing
  retained-set anchor and wrap semantics. This avoids implying that a newly
  created hit was part of the completed pre-write batch.
- Collapse editor selection at the post-write end of the replacement
  corresponding to the pre-write current match. If there was no current match,
  map the pre-action caret through the pure batch plan. R0 must prove Undo
  restores the exact pre-batch selection and Redo restores this mapped
  post-batch selection.

The pure batch plan compares every matched raw slice to the replacement by
literal UTF-16 code units and filters source-identical entries. If all entries
are identical, Replace All performs no writer activation, revision, undo,
rescan, selection, or ordinal change and announces non-color-only
**“No changes.”** If only some are identical, commit only differing ranges as
the one native undo step, report **“Changed X of Y matches,”** map selection
through those actual edits, then perform the normal one post-write rescan.
NFC/NFD differences, `ß`/`SS` case-folded hits, and unequal sub-grapheme ranges
remain real edits whenever their UTF-16 code units differ.

Alternatives rejected:

- preserving the numeric old ordinal;
- assuming replacement length equals match length;
- shifting later ranges by accumulated deltas without a full rescan;
- repeatedly replacing until the query disappears.

All can be wrong when case folding/canonical equivalence changes match length,
whole-word boundaries change, or the replacement creates a new occurrence.

### 5.3 Replace All ceiling, progress, and cancellation

The existing Find ceiling applies to replacement:

| Session state | Replace All |
|---|---|
| Exact, non-truncated, `1 ... 10_000` retained matches | Eligible when every other gate passes. Exactly 10,000 is allowed only when the 10,001 overflow probe did not fire. |
| Exact zero-match state | Disabled/no-op; no plan or progress starts. |
| `isTruncated == true` (engine returned 10,001) | **Refuse with zero mutation.** Present “More than 10,000 matches; narrow the search.” Never replace only the retained prefix while labeling it Replace All. |
| Session missing, recomputing, or revision/generation stale | Refuse and request counter-only recomputation. Never retain a pending Replace All intent across the new result. |

The ceiling is a correctness boundary, not only a memory optimization. A
partial first-10,000 operation would make “All” false and leave an ambiguous
undo/result state.

Replace All has two phases:

1. **Preparing (cancellable):** allocate a monotonic App-owned replacement
   action ID and capture the monotonic replacement-authority/lifecycle
   generation, exact identity/revision/query/options/replacement generation,
   session current ordinal, exact applied-selection provenance, originating
   key-window identity, and exact editor binding/installation. Build the final
   plan/source off-main. Check cancellation after at most **64 planned
   matches** or **65,536 copied UTF-16 code units**, whichever comes first;
   coalesce visible progress to at most **100** monotonic updates
   (`Preparing n / total`).
2. **Committing (not cancellable):** on the main actor, re-check the entire
   captured tuple, the same still-key originating window/editor installation,
   all three marked-text owners (§5.5), and App replacement authorization;
   acquire writer activation, break undo coalescing, and run the R0-approved
   synchronous native batch. There is no suspension between the final
   marked-text/authorization checks, writer preflight, and mutation. Present an
   indeterminate `Applying…` state. Once the authorized closure begins, Cancel
   is disabled; yielding mid-commit would violate the all-or-none, single-undo
   contract.

Query/options/replacement changes, document edits/rebinds, Find
Next/Previous or caret/selection movement, key-window change, editor
remount/rebind, workspace-search activation, bar close/collapse, a newly
appearing authority fence, or explicit Cancel supersede the plan. Workspace-
search focus (`⇧⌘F`) also supersedes it before activation. These events
bump the action or authority/lifecycle generation even if observable values
later return to the same state. Progress and completion apply only while the
full captured tuple still matches; a stale task is drained and dropped with no
mutation. The exact work-chunk ceilings are the v1 responsiveness contract.
R9 measures Cancel-to-task-drain on `Fixtures/large-1mb.md` and freezes a named
local budget from evidence before performance acceptance; hosted wall-clock
evidence is informational under risk R15 (`docs/risk-register.md`).

The synchronous `TextSearchEngine` call is not advertised as interruptible.
Replace All normally consumes the already-computed exact session; if that
session is stale, the action refuses instead of silently starting a future
mutation after a new scan.

The pure plan validates the 256-code-unit replacement limit, then computes
projected post-write UTF-16 length with checked subtraction/addition before
allocation. With at most 10,000 matches, v1 permits at most **2,560,000 UTF-16
code units of growth beyond the already-installed source**. Invalid length or
integer overflow refuses before commit. Swift allocation failure is not
claimed as recoverable; R0/R9 must reject a construction shape whose measured
bounded path is not viable.

### 5.4 Experimental WYSIWYG

All match and mutation coordinates are raw backing-source UTF-16 ranges.
Presentation projection never becomes replacement input.

| Overlap | Required behavior |
|---|---|
| Folded emphasis/heading/strike/code delimiter | Selecting the current match reveals the owning fold region before Replace. Mutate only the exact literal delimiter/content range. Do not repair or rebalance Markdown; malformed post-write markup stays raw. |
| Folded link destination/chrome | Reveal the whole owning link source, replace only the exact raw match range, and perform no URL normalization. Reparse from post-write source. |
| Image region / projected thumbnail | Remove/suspend the projection and reveal the whole raw image source before Replace. Never edit U+FFFC/U+200B projection text. Replace the exact raw image subrange; valid post-write syntax may thumbnail again after selection leaves, invalid syntax stays raw. |

One Replace follows the existing exact-navigation → post-selection reveal →
writer-mutation order. A hidden range is never mutated merely because its old
offset still appears valid.

Replace All does not animate or reveal thousands of regions. It suspends
replace-relevant fold/image presentation for the batch, commits the raw-source
snapshot once, then reparses and reapplies presentation once from
authoritative post-write source. Selection/copy/accessibility remain exact raw
Markdown throughout.

Source-only and source+preview use the same raw mutation. Preview refresh and
scroll behavior flow through normal document publication; this gate never
replaces preview DOM content directly.

### 5.5 IME discipline

Replace and Replace All are refused when **any** of these owns marked text:

- the installed Markdown editor;
- the owned Find query field editor;
- the owned replacement field editor.

Refusal means:

- no App replacement authorization or writer-activation request;
- no selection/reveal, ordinal consumption, undo registration, or progress;
- no pending mutation that can fire after composition commits;
- Return, Escape, space, and candidate keys remain with the input context.

After composition ends, the user makes a fresh explicit Replace action against
the newly revalidated match/session.

Marked text may begin while an off-main Replace All plan is preparing without
changing source or field generations. The final main-actor check therefore
re-reads editor, query-field, and replacement-field marked-text ownership; a
new composition invalidates the action ID and drops the plan before writer
activation.

R6 includes deterministic marked-text tests, but only the owner-run real macOS
Zhuyin/Pinyin harness closes the boundary gate. It follows the existing
opt-in TIS/CGEvent precedent and covers source mode plus Experimental WYSIWYG
at plain text, a folded delimiter, a hidden link-destination edge, and an image
region boundary. A skipped/non-composing Pinyin source is not passing evidence.
Proposed owner command:
`cd Packages/EditorKit && PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter EditorReplaceActualIMEGateTests`.

### 5.6 External reconciliation, quarantine, and commit authorization

Replace is intentionally stricter than ordinary typing while source/disk
authority is unsettled. It must not turn a recoverable conflict into a
multi-match local rewrite or implicitly choose Keep Mine.

| State | Required behavior |
|---|---|
| External observation or Reload / Keep Mine banner awaits a choice | Refuse Replace and Replace All. Keep query, replacement, exact source, selection, ordinal, undo history, and disk-recovery state unchanged. |
| Reload / Keep Mine intent captured, read in flight, source publication pending, or live editor installations not yet converged | Refuse. Existing writer activation also fences these active transitions, but the replacement-specific authorization remains required. |
| Any `committedButIndeterminate` write quarantine, whether the target is readable or awaiting Check Again | Refuse until explicit reconciliation fully clears the retained quarantine and authority. Merely becoming readable does not enable Replace. |
| Workspace-mutation write fence, indeterminate workspace mutation, recovery-fenced missing/detached formerly-backed authority, or pending editor source | Refuse; no partial or queued mutation. |
| Reload completes | Counter-only rescan from accepted disk source/revision; controls become eligible only after installation convergence and a fresh explicit action. |
| Keep Mine completes | Revalidate/rescan the retained local source against the newly adopted baseline; require a fresh explicit action. |

Current writer activation does not cover every prompt/quarantine state above.
R7 therefore requires a plain, App-owned, STTextView-free replacement
authorization capability for the exact focused session. It is checked:

1. when validating a menu/button action; and
2. again at commit, immediately before writer activation, with no suspension
   between the final authorization, preflight, and native mutation.

UI disabled state is not authority. Reusing `canSave` wholesale is also not the
contract: replacement needs a named decision over the exact states above so a
future save-only condition cannot accidentally change editability.

An ordinary valid, installed untitled/in-memory document is not refused merely
because it has no URL: Replace is a source edit. Only the explicit recovery
fences above block such authority.

An App authorization refusal happens before writer preflight and therefore has
zero source/selection/undo/ordinal effect. If authorization passes but writer
preflight discovers a stale native installation, the existing WS3B contract
may synchronize that view and clamp its selection before refusing the requested
replacement. That convergence is not a partial Replace: no replacement undo
group opens, no replacement text applies, no intent is queued, and Find
recomputes counter-only before a fresh explicit retry.

If a fence appears after Replace All planning but before commit, the monotonic
authority generation changes; the full plan tuple fails and no undo group is
opened.

### 5.7 Hard constraints

1. **One matcher.** Existing `TextSearchEngine` + `EditorFindSession` only.
2. **One writer boundary.** Every character mutation through WS3B writer
   activation; App authorization is additional, not a substitute.
3. **Literal v1.** No regex/captures/templates; `$1` is ordinary text.
4. **Current document only.** Workspace-wide replace remains deferred.
5. **STTextView abstraction.** App/ and MarkdownCore/ import no STTextView type.
6. **No marked-text mutation.** Refuse; never auto-commit or queue.
7. **Exact snapshot.** Monotonic action/authority generations, identity, source
   revision, query/replacement generation, current ordinal, match range,
   key-window/editor installation, and applied-selection provenance must agree
   at commit.
8. **No partial Replace All.** Overflow, cancellation, stale state, failed
   authorization, or failed preflight causes zero replacement and no new undo;
   stale-writer authoritative convergence remains limited to §5.6.
9. **Native undo.** No bespoke App-level source rollback; R0-approved native
   undo only.
10. **Bounded v1 growth.** Replacement is at most 256 UTF-16 code units; the
    exact session is at most 10,000 matches and never truncated for Replace All.
11. **No dependency or project-file change** without a separate reviewed need.

## 6. Architecture sketch (names non-binding; capabilities binding)

### 6.1 MarkdownCore — pure replacement model

A pure replacement planner may contain:

- literal replacement value (including empty);
- exact `EditorFindSession` query, match snapshot, and truncation state;
- explicit post-replace current/unresolved ordinal state without changing
  matching semantics;
- one-match plan and exact-set batch plan;
- literal UTF-16 identical-range filtering and changed/total counts;
- bounded-length/overflow/stale/invalid validation states;
- reverse-range or final-source construction with overflow-safe UTF-16 math;
- `resumeUTF16` and post-write current-ordinal resolution;
- progress accounting independent of UI.

It consumes matches; it does not search. Full post-write recomputation calls
the existing `EditorFindSession.search` / `TextSearchEngine`.

No I/O, actor, undo, AppKit, STTextView, or document authority lives here.

`EditorReplaceSourceConstruction.replacedSlice(_:enclosing:ranges:replacement:)`
builds the local text for B1's one enclosing-range edit. It validates the entire
ordered, non-overlapping range list and enclosing source bounds before rebasing;
untouched gaps remain literal, and an empty list returns the unchanged slice.
`EditorReplaceSourceConstructionTests` covers Unicode, deletion, adjacent edits,
padding, empty ranges, malformed/overflowing lists, and ranges escaping the slice.
The R0 spike (#112) consumes it: `EditorReplaceBatchSpike.plan` takes B1's slice
and range validation from this type and B2's whole-document text from
`replacedSource`, keeping no EditorKit construction copy. This model-only work
claims no R0 mechanism change.

### 6.2 EditorKit — installed editor executor

EditorKit owns:

- command delivery to the editor in the key window;
- exact applied-selection and installed-source proof;
- marked-text refusal for the editor;
- WYSIWYG reveal/suspension and post-write presentation reapply;
- synchronous writer activation and native mutation;
- `breakUndoCoalescing`, R0-approved undo boundary, selection restoration, and
  publication observation;
- one Replace result / one Replace All result returned as plain values.

The executor never accepts an App URL as mutation authority and never imports
WorkspaceKit.

### 6.3 App — product state and authorization

App owns:

- replacement row expansion/value, validation, progress, and accessibility;
- Edit-menu items and existing key-window responder fallback;
- query-field focus receipt and workspace-search arbitration;
- exact current-session replacement authorization (§5.6);
- monotonic action/authority lifecycle supersession for edit, selection,
  rebind, reload, rekey, focus/window changes, fences, collapse, and close;
- counter-only post-resolution rebind/recompute.

App does not import STTextView, calculate replacement ranges, or assign source
text.

### 6.4 Performance shape

- Matching remains the in-flight Find controller's off-main path.
- Replace All final-source construction runs off-main and is cancellable before
  commit.
- The R0-approved native commit is synchronous and never yields partial state.
- Progress callbacks are bounded/coalesced and never emitted from the typing
  hot path.
- Post-write matching is one off-main full rescan, not one scan per match.
- WYSIWYG/preview reapply is once per batch, not once per retained match.

## 7. Review-sized PR split

All implementation PRs branch from updated `origin/main` after their
prerequisite lands. Do not stack on the in-flight Find highlight/XCUITest/
latency work or edit its shared surfaces concurrently.

| PR | Scope | Expected gates (only with evidence) |
|---|---|---|
| **A — this PR** | Spec only: `docs/editor-replace-gates.md` + one concise Decision Log row. No behavior, dependency, code, tests, or checked box. | none |
| **B — mechanism spike** | **R0 only.** Hosted writer-authority fixture; compare authorized outer-group/reverse edits, one minimal-enclosing-range edit, and full-document fallback separately. Record undo/redo, publication, prior-typing separation, selection, WYSIWYG, Unicode, near-ceiling, bounds, and 1 MiB evidence. No user-facing Replace. | R0 or a recorded NO-GO/design stop |
| **C — pure model** | MarkdownCore plans, 256-code-unit validation, identical-range filtering, ceiling/output math, continuation/anchor state, full-rescan ordinal behavior, and pattern/boundary cases. No mutation or UI. | R1 and R3 model bullets |
| **D — source-only single Replace** | EditorKit current-match executor through writer activation, exact applied selection, native undo, replacement-aware publication, one rescan, and ordinal continuation. No App lifecycle policy, visible UI, or WYSIWYG overlap work. **Outcome:** R2 and the R3 integration bullets close. WYSIWYG presentation installed refuses with zero effect until PR F. | R2 and R3 integration |
| **E — App authorization/lifecycle** | Plain App commit authorization, external/reload/quarantine fences, monotonic plan supersession, untitled authority, key-window/install proof, and hosted lifecycle matrix. No new product chrome. | R7 |
| **F — Experimental WYSIWYG** | Single-Replace raw-source reveal/suspend/reapply for folded delimiter, hidden link destination, and image region; source+preview publication. | R5 single-Replace/source-preview bullets; R5 remains open |
| **G — Replace All pipeline** | R0-approved executor, bounded off-main cancellable plan/progress, stale-drop, output/ceiling refusal, changed/total reporting, one rescan, mapped anchor, one undo, and one batch WYSIWYG suspend/reapply. | R4, R5 batch bullet, and Replace All portions of R2/R3 |
| **H — product UI + deterministic IME** | Expand existing bar; owned replacement field; menu/responder routing and visibility eligibility; focus-token arbitration; blocked/progress/accessibility states; deterministic marked-text tests. | R6 deterministic half and R8 |
| **I — acceptance/performance** | XCUITest, owner-run real Zhuyin/Pinyin boundary harness, and `Fixtures/large-1mb.md` Replace All/cancellation/typing-latency measurements. | R6 owner half, R9, R10 |

Before declaring an implementation PR done: relevant package/hosted tests,
`make format`, `make lint`, `make test`, `make build`, and
`git diff --check`. PR bodies list gates actually closed and those still open.

## 8. Gates

Boxes stay unchecked until a later PR supplies named-test or owner-recorded
evidence. R1 and the R3 model bullets are checked in PR C; R0 is checked by the
hosted spike PR #112.

### R0 — Batch writer activation + one undo (blocking mechanism spike)

- [x] Build a hosted coordinator fixture with a real App source contract,
  writer activation, native undo manager, source publication observation, and
  Experimental WYSIWYG path.
  Evidence: `EditorReplaceBatchSpikeSupport` + `EditorReplaceBatchSpikeAppTests`
  (`DocumentSession` / `AppState.editorDocumentBinding`).
- [x] Candidate A: one activation, `breakUndoCoalescing()` before an explicit
  outer undo group, reverse-ordered replacements through the authorized native
  edit helper.
  Evidence: `EditorReplaceBatchSpikeTests.testCandidateAPublishesOncePerMatch`
  and `EditorReplaceBatchSpikeUndoTests.testReverseOrderedEditsShareOneOuterUndoGroup`.
  **NO-GO for Replace All:** one undo group, but N source publications.
- [x] Candidate B1: exact final source built before activation, then one native
  edit of the minimal enclosing raw range.
  Evidence: `EditorReplaceBatchSpike.plan` (text from MarkdownCore's
  `EditorReplaceSourceConstruction.replacedSlice`) +
  `testCandidateB1PublishesOnceForTheEnclosingRange` — 1 writer activation, 1
  authorized native edit, 1 publication.
  `testInvalidRangesOpenNoWriterOrUndo` refuses overlapping ranges before
  writer activation or undo grouping.
- [x] Candidate B2 is measured separately, and only if B1 fails: one
  full-document native replacement.
  Evidence: `testCandidateB2PublishesOnceForTheFullDocument`. B1 did not fail;
  B2 remains an unused fallback.
- [x] One Undo restores literal UTF-16-code-unit-exact source, selection, and
  dirty baseline for the entire batch; no second Undo is needed for another
  match. Fold-delimiter attributes are reasserted by the existing highlight
  presentation pass after the undo publication, not by the batch helper.
  Evidence: `testMinimalEnclosingRangeIsOneUndoAndRedo` (source/selection/dirty);
  `EditorReplaceBatchSpikeWYSIWYGTests.testMinimalEnclosingRangeUndoRestoresFoldPresentation`
  (live `foldedDelimiterAttribute` on the `**` ranges of `**one**` after apply
  and again after undo + presentation reapply).
- [x] One Redo reapplies the exact whole batch, including the planned
  post-batch caret.
  Evidence: `testMinimalEnclosingRangeIsOneUndoAndRedo`.
- [x] Seed prior typed/coalesced input first: Replace All must not merge with
  it; the next Undo after undoing Replace All reaches the prior input.
  Evidence: `testReplaceAllDoesNotMergeWithPriorTyping`.
- [x] Record activation, native edit, source publication, and revision.
  One undo with N intermediate publications is not sufficient evidence.
  Evidence: A = N edits / N publications (NO-GO); B1 = 1/1 (GO); B2 = 1/1
  (fallback). Presentation stays outside the mutation; the WYSIWYG test
  asserts live folded-delimiter attributes after apply and after undo.
- [x] Cover unequal lengths, deletion, Unicode/canonical-equivalent match
  lengths, replacement containing the query, 256-code-unit replacement, and a
  near-10,000 exact set.
  Evidence: `testDeletionAndUnequalLengths`,
  `testCanonicalEquivalentMatchLengthComesFromTheEngineRange`,
  `testReplacementContainingTheQueryIsNotRescannedInTheBatch`,
  `testTwoHundredFiftySixCodeUnitReplacement`,
  `EditorReplaceBatchSpikeLargeDocumentTests` (`an` × 8,921 on `large-1mb.md`).
- [x] App authorization refusal opens no writer/undo work. Stale writer
  preflight may perform only its existing authoritative convergence; it applies
  no replacement, opens no replacement undo group, and requires counter-only
  recompute.
  Evidence: `testAuthorizationRefusalOpensNoWriterOrUndo`,
  `testStaleWriterPreflightDoesNotOpenAReplacementUndoGroup`.
- [x] Run the combined worst v1 shape: `Fixtures/large-1mb.md`, an exact
  near-10,000 non-truncated set, and a 256-code-unit replacement; record
  construction, main-thread, and typing impact.
  Evidence: asserted `an` × 8,921 and planned UTF-16 length 3,314,896;
  printed (not wall-clock-gated) construction ≈ 4.5 ms; B1 commit ≈ 42 ms;
  post-batch `insertText` ≈ 0.5 ms. Allocation is not measured. These numbers
  predate the switch to MarkdownCore's builder; the 2026-09-21 Decision Log row
  records the same-machine before/after comparison.
- [x] Record GO candidate or NO-GO. If no allowed candidate passes, Replace All
  remains deferred and this design changes before any product UI claims it.
- Evidence: **GO — Candidate B1.** No user-facing Replace. B1 and B2 text come
  from PR C's `EditorReplaceSourceConstruction`; product mutation stays behind
  later PRs.

### R1 — One literal match semantics

- [x] Replacement planner consumes only `EditorFindSession` matches from
  existing `TextSearchEngine`; no second matching path.
- [x] Smart/sensitive/insensitive, whole-word, invalid query, canonical
  equivalence, and non-overlap agree exactly with Find.
- [x] Match length is taken from returned UTF-16 range, never query length.
- [x] Empty replacement deletes; `$1`, `\1`, and `\n` are literal, not
  templates/escapes.
- [x] Replacement accepts at most 256 UTF-16 code units; multiline/over-limit
  values are explicitly invalid without changing search semantics.
- [x] Source-identical comparison is literal UTF-16 code-unit equality, not
  canonically equivalent Swift `String ==`.
- [x] Regex input or mode cannot be enabled by the Replace surface.
- [x] Plans cover the whole current installed document/session only; no
  selection-scoped mode, workspace enumeration/fan-out, or workspace-wide
  replacement path exists.
- Evidence: `EditorReplaceFindAgreementTests` (`testPlannerConsumesExactFindSessionRanges`,
  `testInvalidFindQueriesProduceEmptySessionRefusal`,
  `testBatchUsesEntireSessionNotASelection`);
  `EditorReplaceOneMatchPlanTests` (`testPlanUsesSessionCurrentMatchNotASecondScan`,
  `testPlannerDoesNotRescanTheProvidedSource`,
  `testMatchLengthComesFromTheEngineRange`,
  `testEmptyReplacementDeletesAndTemplatesStayLiteral`);
  `EditorReplaceValidationTests` (`testEmptyReplacementIsValid`,
  `testLiteralDollarAndEscapeSequencesAreValid`,
  `testActualNewlinesAreInvalid`,
  `testFindAndReplaceRejectEverySingleLineSeparator`,
  `testIndependentReplacementDefaultMatchesQueryScaleAndDerivesGrowthCap`,
  `testTwoHundredFiftySixCodeUnitsAreValidAndTwoFiftySevenAreNot`,
  `testLiteralIdentityUsesUTF16NotCanonicalStringEquality`,
  `testMalformedRangesFailClosedWithoutEndOverflow`).
  Model-only: no Replace surface or regex mode exists; `TextSearchQuery` remains
  literal and `a.b` is not a regex.

### R2 — Exact current-match mutation through writer activation

- [x] Replace requires exact identity/revision/query generation, current match,
  installed state, and applied selection range.
- [x] A not-yet-applied match navigates/reveals only; it does not mutate or
  queue a later mutation.
- [x] The successful character edit runs only inside the WS3B
  writer-authorized synchronous closure and uses native insertion.
- [x] `STTextFinderClient.replaceCharacters`, direct `textStorage` character
  writes, and App binding assignment are absent.
- [x] App and MarkdownCore import/name no STTextView type; concrete editor
  mutation remains confined to EditorKit.
- [x] No new Swift/npm dependency or project-target change is introduced.
- [x] Failed App authorization has zero source/selection/ordinal/progress/undo
  effect. Failed writer preflight may only synchronize stale native source and
  clamp selection under its existing contract; it performs no replacement,
  opens no replacement undo group, and queues no retry.
- [x] One source-changing Replace is one native undo step and preserves prior
  undo history; the literal-identical path creates no undo entry.
- Evidence: `EditorReplaceExecutorTests` (`testSourceChangeIsOneUndoAndPreservesPriorTyping`,
  `testNotAppliedMatchNavigatesWithoutMutationOrQueue`,
  `testMarkedTextRefusesBeforeAuthorization`,
  `testAuthorizationRefusalHasZeroEffectBeforeWriterPreflight`,
  `testStaleWriterPreflightOpensNoReplacementUndo`,
  `testStaleIdentityAndInvalidReplacementDoNotMutate`,
  `testLiteralIdenticalAdvancesWithoutWriterRevisionUndoOrRescan`,
  `testCanonicalDifferenceIsARealEdit`);
  `EditorReplaceLayeringTests` (`testAppAndMarkdownCoreDoNotImportSTTextView`,
  `testSingleReplaceDoesNotUseForbiddenMutationAPIs`,
  `testNoProjectOrPackageDependencyChange`); these read checked-in sources and
  manifests only (no git refs), pinning every `.package` declaration,
  `project.yml` package/target/dependency entry, and preview-src npm dependency
  name. `EditorReplaceWriteOutcomeTests` (`testRefusedNativeInsertionIsNotReportedAsReplaced`,
  `testRejectedPublicationIsNotReportedAsReplaced`) prove a refused insertion or
  rejected publication is `.refused(.writeNotApplied)` with Find untouched, and
  `testTypingAfterReplaceIsASeparateUndoStep` proves key-event typing after
  Replace is its own undo group (one Undo keeps the replacement).
  WYSIWYG presentation installed is refused with zero effect
  (`testWYSIWYGPresentationRefusesWithZeroEffect`); PR F/G evidence below
  supplies the later R5 closure.

### R3 — Post-write rescan and ordinal

- [x] One source-changing Replace publishes authoritative post-write
  text/revision, then performs exactly one full existing-engine rescan.
- [x] Replacement-aware publication consumes that revision once, suppressing/
  coalescing the same revision's ordinary `.edit` Find schedule while all other
  document-text consumers still receive normal publication.
- [x] `resumeUTF16 = oldStart + replacementUTF16Length`; new current is the
  first retained recomputed start at/after it.
- [x] No automatic wrap; no later retained match means current `nil` /
  `0 / total` until explicit Next.
- [x] Replacement-created matches are counted but starts inside the inserted
  span are skipped for automatic continuation.
- [x] Boundary-created/destroyed whole-word and canonical-equivalent matches
  come only from the full rescan, not delta-patched ranges.
- [x] A literal-identical single Replace performs no writer/revision/undo/
  rescan, but advances within the unchanged retained session without implicit
  wrap.
- [x] A no-later source-changing or literal-identical Replace stores
  `caretAnchorUTF16 = resumeUTF16` / old match end respectively and collapses
  selection there before explicit Next/Previous uses retained-set wrap.
- [x] A truncated single Replace, including replacement containing the query
  and the 10,000th retained match, continues only within the recomputed retained
  prefix; it never starts an unbounded second scan.
- [x] Replace All consumes its pre-write set once, rescans once, and leaves
  current `nil` with the mapped post-batch selection as `caretAnchorUTF16`;
  replacement-created hits are never recursively replaced.
- Evidence: model bullets —
  `EditorReplaceContinuationTests` (`testPlanBindsTheQueryUsedForPostWriteRescan`,
  `testSourceChangingOneReplaceRescansAndSkipsInsertedSpan`,
  `testNoLaterMatchLeavesCurrentNilUntilExplicitNext`,
  `testTruncatedSingleReplaceContinuesOnlyInTheRetainedPrefix`,
  `testReplaceAllRescansOnceAndClearsCurrent`);
  `EditorReplaceContinuationRescanTests` (`testWholeWordDestructionComesFromFullRescan`,
  `testWholeWordCreationAfterResumeComesFromFullRescan`,
  `testCanonicalEquivalentRemainderComesFromFullRescan`,
  `testReplacementCreatedHitsAreCountedAndSkipped`,
  `testTruncatedReplacementContainingQueryStaysInPrefix`);
  `EditorReplaceOneMatchPlanTests` (`testLiteralIdenticalSkipsMutationAndAdvancesToNextStart`,
  `testLiteralIdenticalAtLastMatchLeavesCurrentNilWithoutWrap`);
  `EditorFindSessionUnresolvedCurrentTests`.
  `testNoLaterMatchLeavesCurrentNilUntilExplicitNext` explicitly asserts the
  source-changing resume, session anchor, and collapsed selection before wrap.
  Integration bullets —
  `EditorReplacePublicationTests` (`testReplacementRescansOnceAndSkipsTheInsertedSpan`,
  `testSameRevisionOrdinaryEditCannotWin`,
  `testNoLaterMatchCollapsesAtResumeWithoutWrap`,
  `testStepPressedDuringReplacementRescanIsApplied`,
  `testReplacementRescanDoesNotWaitForTypingDebounce`,
  `testEditDuringReplacementRescanSupersedesContinuation`,
  `testRoutedPublicationNotifiesFindAfterTheWriterClosure`);
  `EditorReplaceExecutorTests.testLiteralIdenticalAdvancesWithoutWriterRevisionUndoOrRescan`,
  `testLiteralIdenticalAtLastMatchCollapsesWithoutWrap`;
  `EditorReplaceWriteOutcomeTests` (`testNonUnitRevisionAdvanceStillAdmitsOneReplacementRescan`,
  `testReconciledPublicationIsAnUnverifiedWriteAndAnOrdinaryEdit`,
  `testClearForNoDocumentDuringWriteIsNotAdmitted`,
  `testRebindDuringWriteIsNotAdmitted`,
  `testUnobservableSnapshotAfterInsertIsUnverified`);
  `EditorReplaceSingleReplaceAppTests` (`testSingleReplacePublishesToDocumentConsumersAndRescansOnce`:
  document text stream, dirty state, and autosave scheduling still run; Find
  admits one `.replacement` rescan and zero `.edit` schedules for that revision.
  `testAppRoutedPublicationNotifiesFindObserversAfterTheWrite`: App's
  publication reaches Find inside the write, is recorded once, and Find's
  session observer runs only after the writer-authorized closure).
  `EditorReplaceOffsetMappingTests` covers two preceding unequal-length edits,
  adjacent-match start mapping, current-match end ownership at an adjacent
  following edit, and clamping all three batch caret outputs to
  the same post-write offset. `EditorReplaceSourceConstructionTests` also proves
  offset mapping rejects malformed suffixes even when the caret precedes them.
  PR D closes the publication, writer, revision, undo, and literal-identical
  integration bullets above. PR G product evidence: `EditorReplaceBatchExecutorTests`
  (`testProductB1OneEditPublicationUndoRedoAndPriorTypingSeparation`,
  `testCanonicalUnequalRangesAreChangedOnceAndInsertedQueryIsNotRecursive`,
  `testMixedIdenticalCountsAnd256UnitReplacement`,
  `testNoChangesPreservesSourceSelectionOrdinalRevisionUndoAndRescan`,
  `testRejectedWriteLeavesNoSelectionUndoAndPreservesPriorTyping`) and hosted
  `testHostedReplaceAllSourceOnlyPublishesOnceRescansOnceAndUndoRedoSelection`,
  `testHostedReplaceAllUndoDoesNotMergeWithPriorTyping`,
  `testHostedReplaceAllCanonicalEquivalentUnequalRangesMapsThirdMatchCaret`,
  `testHostedReplaceAllReplacementContainingQueryIsNotRecursivelyReplaced`,
  `testHostedReplaceAllLargeFixtureEightThousandNineHundredTwentyOneWithMaximumReplacement`.
  The executor fixture counts one activation/native edit/publication; hosted
  checks the App revision, replacement publication/schedule/engine invocation,
  exact source, mapped anchor, native Undo/Redo selection and dirty baseline.
  The large fixture retains `an` x 8,921 and a 256-UTF-16-unit replacement.

### R4 — Replace All ceiling, cancellation, and progress

- [x] Exact non-truncated sets through 10,000 are eligible; 10,001 overflow
  refuses with a typed reason and zero mutation. Non-color-only user-visible
  text is R8 / PR H scope.
- [x] A stale/missing/recomputing session refuses; it does not retain a pending
  batch intent.
- [x] Final-source/plan preparation runs off-main, checks cancellation after at
  most 64 matches or 65,536 copied UTF-16 code units (whichever comes first),
  and emits at most 100 monotonic progress updates.
- [x] Replacement is at most 256 UTF-16 code units. Checked projected-length
  math bounds growth to 2,560,000 code units; invalid length or integer
  overflow refuses before allocation/writer activation. The maximum-growth
  guard is defensive and unreachable by construction: 10,000 positive-length
  matches × at most 255 units of net growth = 2,550,000 < 2,560,000.
  No recoverable Swift allocation-failure promise is made.
- [x] A monotonic action ID and authority/lifecycle generation fence the exact
  identity/revision/query/options/replacement generation, current ordinal,
  applied selection, key window, and editor installation.
- [x] Query/options/replacement changes, edits/rebinds, navigation/selection,
  key-window/remount, workspace-search focus/activation, close, Cancel, or a new
  fence bumps a monotonic token and supersedes the plan even if values later
  return. Collapse is a tested authority-generation seam; PR H must call it
  from the real disclosure UI and add its UI-level test under R8.
- [x] Immediately before writer activation, with no suspension before
  mutation, commit rechecks the full tuple, App authorization, and marked text
  in editor/query/replacement fields.
- [x] Commit uses only the R0-approved single-undo mechanism and is explicitly
  non-cancellable once its synchronous native closure starts.
- [x] Cancel before commit leaves exact source, selection, ordinal, undo, and
  presentation unchanged; task cancellation is observed at the deterministic
  R4 work-chunk boundaries.
- [x] All-literal-identical batches report “No changes” with no writer,
  revision, undo, rescan, selection, or ordinal change. Mixed batches change
  only differing ranges in one undo and return changed/total counts.
  “No changes” / “Changed X of Y matches” presentation belongs to R8 / PR H.
- Evidence: full `EditorReplaceBatchPreparationTests` (15 tests) and
  `EditorReplaceBatchExecutorTests` (nine tests) pass. Preparation tests name
  exact 10,000 / 10,001 refusal, deterministic 64-match and 65,536-unit
  cancellation (including prefix/suffix construction and surrogate boundaries),
  at-most-100 monotonic progress, invalid replacement/range/overflow refusals,
  no changes and mixed literal identity. Checked growth additionally reuses
  `EditorReplaceValidationTests` and `EditorReplaceBatchPlanTests`.
  The hosted methods in `EditorReplaceBatchHostedCorrectnessTests`,
  `EditorReplaceBatchHostedSupersessionTests`, and
  `EditorReplaceBatchHostedCommitGateTests` execute as `EditorFindHostedGateTests`.
  Named event-family tests cover query/options/replacement ABA, edit/rebind,
  navigation/native-selection ABA, key-window ABA/remount, workspace-search
  focus/activation (including an already-superseded Find focus token with no
  command-context override), close, the future collapse seam, explicit
  Cancel/caller cancellation and fence ABA,
  each with zero batch write and no new undo. Final fence and owned-field
  marked-text rechecks refuse before writer/undo; real native editor and query
  `setMarkedText` at entry start no preparation. Product EditorKit additionally
  tests marked text appearing after preparation and authorization refusal.
  `testHostedReplaceAllCommitIsNonCancellableOnceNativeWriteStarts` cancels
  during the authorized native write and still admits one coherent batch.
  Missing/recomputing/stale sessions keep no pending intent; the off-main/progress
  and both held cancellation-boundary hosted methods assert the worker result
  itself is `.failure(.cancelled)`, beyond the caller result. Explicit Cancel
  returns `.cancelled`; marked text and supersession each have one App result
  shape regardless of the refusing layer. A stale retained session requests
  counter-only recomputation. The WYSIWYG Cancel fixture contains settled
  folds/images and compares their ranges and image signatures.
  `EditorReplaceBatchDifferentialTests` compares the checkpointed plan, slice,
  exact expected source and mapped selection with the reference builders on
  fixed-seed Unicode/case/whole-word cases and 33 surrogate-heavy documents.
  Refusals/outcomes/progress are typed plain values for PR H's non-color-only
  messages. The absent replacement field plugs into the same marked-text owner
  registry in PR H; owner real-IME acceptance stays under open R6.

### R5 — Experimental WYSIWYG raw-source replacement

- [x] Folded delimiter overlap reveals the owning region, replaces the exact
  raw-source UTF-16 span, and performs no Markdown repair.
- [x] Folded link-destination overlap reveals the whole link, replaces only
  the raw match, and performs no URL normalization.
- [x] Image overlap removes/suspends projection, replaces exact raw image
  source, and never mutates projected U+FFFC/U+200B text.
- [x] Valid post-write constructs may fold/thumbnail again only after reparse;
  invalid constructs remain raw and editable.
- [x] Replace All suspends/reapplies presentation once per batch, not once per
  match; backing source, copy, selection, and accessibility remain canonical.
- [x] Source-only and source+preview publish through the normal document/
  preview path; no preview DOM mutation.
- Evidence (PR F single Replace; PR G closes the remaining batch bullet below):
  `EditorReplaceWYSIWYGTests.testFoldedDelimitersNavigateThenReplaceExactSpanAndUndoRedo`
  covers emphasis/strong/heading/strike/code, CJK/emoji UTF-16 spans, the literal
  post-write source, and the fold kinds the parser derives from it (`*字🦊**` is
  emphasis plus a literal `*`; the other malformed results have none).
  `testLinkDestinationRevealsWholeSourceWithoutURLNormalization`
  proves whole-link raw reveal and unchanged parentheses/percent-escape spelling
  outside the exact match. `testImageProjectionNavigatesRevealsAndRebuildsAfterUndoRedo`
  removes the owning marker on navigation and edits backing source only;
  `testInvalidImageAfterReplaceStaysRawAndEditable` proves invalid syntax stays raw.
  `testAdjacentMatchNeitherRevealsFoldNorRefuses` proves strict overlap;
  `testRefoldedPresentationAtStillValidOffsetRefusesWithZeroEffect`,
  `testWholeLinkProofRejectsHiddenChromeOutsideTheMatch`, and
  `testImageProjectionReinstalledAtExactSelectionRefusesWithoutReveal` cover stale
  or partially hidden presentation with no writer/publication/undo effects.
  `testMarkedTextWithWYSIWYGRefusesBeforeAuthorizationOrReveal` extends deterministic
  editor coverage only, with no R6 checkbox change.
- Nested-fold review fix (bullets 1–3): an owner the match touches is revealed,
  while a construct nested in it but untouched stays folded. The proof checks the
  match plus each owner's own fold ranges, not the owner's whole source. Each of
  these failed before the fix (`wysiwygRangeNotRevealed` on every attempt) and now
  commits on the action after navigation, with the nested fold still hidden:
  `testHeadingOwnerWithUntouchedFoldedStrongCommits` (`# Title **bold** word`),
  `testHeadingOwnerWithUntouchedFoldedLinkCommits`
  (`## See [Astro](https://astro.build) docs`),
  `testLinkDestinationWithUntouchedFoldedCodeInLinkTextCommits`
  (`` Intro [`code` docs](https://host/a) tail ``, query `host`),
  `testStrongOwnerWithUntouchedFoldedEmphasisCommits` (`Intro **very *it* note** tail`),
  and `testHeadingOwnerWithUntouchedImageProjectionCommits` (the untouched image
  keeps its marker). After the selection leaves, owner and nested construct both
  refold. `testWholeLinkProofRejectsHiddenChromeOutsideTheMatch` still refuses a
  hidden `[`. `testNestedFoldInLinkTextStillRejectsEveryHiddenChromePiece` covers
  `Intro [**bold** text](https://host/a "T") tail`, query `text`: hiding any one of
  `[`, `]`, `(`, the URL, `"T"`, `)`, or the whole `](…)` refuses with zero writer
  activations. `testRevealedLinkChromeWithUntouchedNestedBoldCommits` commits with
  revealed link chrome while the untouched nested bold remains folded.
  `testRejectedPublicationWithWYSIWYGLeavesNoUndoStepRawSourceAndRederivablePresentation`
  covers `.refused(.writeNotApplied)` under WYSIWYG: no undo/redo step, unchanged
  source/copy/accessibility, no newly hidden range, and an unadvanced applied model.
  Handoff 21's reconciled-source presentation fix restarts the normal 20 ms
  highlight scheduler after PR D's rejection restore (`applyReconciledSource` →
  `textView.text =`, shared with source mode). Pending presentation stays raw; the
  automatic fresh parse restores the identical untouched fold set without another
  edit or selection change. A reconciliation revision floor rejects pre-restore
  results; image generations and Find decoration caches are invalidated with storage.
  Hosted evidence:
  `testHostedRejectedReplaceAutomaticallyRestoresWYSIWYGFoldsLinksAndImageMarkers`
  and `testHostedRejectedReplaceAutomaticallyRestoresSourceHighlightWithoutTypingOrSelectionChange`
  drive the normal App publication refusal and production scheduler. See
  [reconciled-source verification](perf-log.md#reconciled-source-presentation--2026-10-05).
  R5 batch, R6 real-IME and R9 performance acceptance remain open.
- Production App evidence is in `EditorFindHostedGateTests`:
  `testHostedReplaceFoldedDelimiterThroughDispatcherAndAutomaticReparseUndoRedo`,
  `testHostedReplaceLinkDestinationThroughDispatcherWithoutURLNormalization`,
  `testHostedReplaceImageThroughDispatcherAndAutomaticThumbnailUndoRedo`,
  `testHostedReplaceInvalidImageRemainsRawEditableAfterAutomaticReparse`,
  `testHostedReplaceInvalidDelimiterStaysRawWithoutMarkdownRepair`, and
  `testHostedReplaceInsideRevealedHeadingWithNestedFoldedStrongCommits` drive #131's
  dispatcher and both App authorization checkpoints. The first action only
  navigates; the next commits exactly one raw range. Fresh applied model revisions
  and original Undo source ranges check **automatic** post-write/Undo/Redo reparse,
  without a test-side reparse or presentation repair. Valid constructs refold or
  thumbnail after selection leaves; invalid ones remain raw/editable. Exact source,
  raw selection/copy/accessibility and one Undo/Redo step are asserted.
  `testHostedReplaceSourceOnlyAndSourcePreviewPublishNormally` asserts one
  replacement publication and reads the normal live preview; it does not mutate
  the DOM. Historical review-fix runs on `.task(id:)` had two automatic-reparse
  timeouts (folded delimiter and image); the other five methods passed.
- Scheduler dependency: the highlight-scheduling bug-fix PR
  (#136, `phase3-editor-highlight-schedule-fix`) owns the Task scheduler.
  Replace F stacks on it. The trace showed `body` evaluating the final revision without
  restarting the task, then the old task stopping at its revision guard. Both historical
  hosted timeouts were attributed to this dropped request. Under load about 12–19 the folded
  test failed 8/15 with `.task(id:)` and passed 15/15 with the original direct Task;
  a deterministic reproduction of the SwiftUI drop could not be forced. The bug-fix PR
  adds deterministic cancellation/coalescing tests and an opt-in stress reproduction.
  The final bounded implementation and interleaved A/B typing evidence live in its
  [perf entry](perf-log.md#editor-highlight-scheduling-fix--2026-10-01).
- Typing: Replace F's own addition remains an O(1) snapshot recorded once per applied
  highlight, never per keystroke. The scheduling change is inherited from the separate
  bug-fix PR. The unchanged native-edit and marked-text guards remain in force.
  Hosted typing is opt-in (`TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE=1`), with the
  unchanged 16 ms budget and idle-machine measurement pending. Historical review-fix
  counts and failures remain recorded in the perf log. Post-restack verification:
  full EditorKit 411 tests (seven real-IME opt-in skips), hosted EditorFind/EditorReplace
  plus nine App WYSIWYG policies 125 tests (four opt-in skips), zero failures. Both
  previously timed-out automatic-reparse cases passed 3/3 with no failure retry.
  `make build`, pinned SwiftFormat 0.62.1 lint, and `git diff --check` passed;
  [verification record](evidence/editor-replace-f-restack-20261001.json).
  The reveal proof runs only on explicit Replace. These synthetic native-input
  probes do not close R9 or real IME.

  PR G adds `EditorReplaceBatchExecutor+WYSIWYG.swift` and the hosted
  `testHostedReplaceAllWYSIWYGFoldLinkImageUsesCanonicalSourceAndAutomaticReparse`;
  the implementation performs one attribute-only suspension before the one raw
  insertion and leaves reapplication to the normal post-write highlight/reparse.
  `HostedBatchPresentationObservation` observes TextKit attribute transactions
  during this explicit test only: every attribute-only transaction touching old
  or new fold ranges is counted, including partial-range transactions. After
  presentation quiescence there is exactly one suspension and one authoritative
  post-write fold reapplication, with raw backing text throughout.
  The fixture includes folded delimiters, link destinations, an image, and an
  untouched folded owner; no per-match reveal/reparse is requested. Hosted tests
  also assert canonical copy, raw selection/accessibility, exact Undo/Redo source
  and normal source+preview publication.
  `EditorReplaceBatchWYSIWYGRecoveryTests` covers rejected publication and native
  insertion refusal after suspension: image-cache ownership resets even if source
  is unchanged, and one fresh derivation restores folds and markers without a
  forced marker reapply. The hosted rejected-publication case verifies the normal
  scheduler automatically restores folds/images exactly once after quiescence.
  R5 is closed overall for this pipeline; UI and owner gates remain separate.
  #144 is still open as of this review-fix run. G adopts its additive reset and
  invalidation seams locally; after both merge, retain each shared seam once.
  If `applyReconciledSource` already advances the reset revision, G skips its
  fallback request. The PR landing second must re-run the combined rejected-write
  test on that integration and retain the not-applied-insert coverage.
  No new preparation, progress, or reset work runs per keystroke: the new selection
  observer is installed only during explicit preparation and removed before
  commit; query-owner registration runs on mount/unmount only. Preparation and
  progress tasks begin only in `performEditorReplaceAll`. The additive stale
  highlight floor is a constant-time apply check shared with #144, and reset
  callbacks run only after a failed explicit batch. This is structural
  typing-path evidence, not an idle-machine latency measurement; R9 stays open.

### R6 — Marked text + real Zhuyin/Pinyin boundaries

- [x] Deterministic tests refuse Replace/Replace All while marked text exists
  in the editor, query field, or replacement field.
- [x] Refusal performs no navigation/reveal, authorization/preflight, undo,
  progress, ordinal change, or queued post-composition action.
- [x] Replacement-field Return and Escape defer to the input context while
  marked text exists; after composition a fresh explicit action is required.
- [x] Marked text beginning in any of the three owners during Replace All
  planning invalidates the action at final pre-commit recheck, with no queued
  post-composition mutation.
- [ ] Owner-run real macOS Zhuyin **and composition-capable Pinyin** harness
  covers source mode and Experimental WYSIWYG at plain text, folded delimiter,
  hidden link destination, and image-region boundaries.
- [ ] Owner evidence records TIS input-source IDs, real event route, no skipped
  composition, exact committed source/caret, and exactly one mutation after a
  fresh post-composition Replace.
- Evidence (PR H, deterministic bullets 1–4; synthetic AppKit `setMarkedText` on
  the production owners in a hosted `WorkspaceWindow`, not a real input method):
  - Bullets 1–2:
    `EditorFindHostedGateTests.testHostedMarkedTextInEachOwnerRefusesReplaceAndReplaceAllWithZeroEffect`
    composes in the editor, the query field and the replacement field in turn,
    with the caret deliberately off the current match so a non-refused Replace
    would navigate. `performEditorReplace`, the bar's Replace/Return intent, the
    Edit ▸ Replace menu intent and `performEditorReplaceAll` each return the one
    `.markedText` shape; `lastAuthorizationRecord` stays `nil`; the full
    `EditorReplaceEffectSnapshot` (source, revision, selection, Find session and
    ordinal, undo/redo, shared and pending navigation, recovery maps) is
    unchanged; no preparation or progress starts; the authority generation does
    not move. After composition ends nothing fires. Single Replace now checks all
    three owners in App before validation-time authorization
    (`AppState.editorReplaceHasMarkedText(for:)`), as PR G's Replace All entry
    already did; EditorKit's editor check
    (`EditorReplaceExecutorTests.testMarkedTextRefusesBeforeAuthorization`) stays
    as defense in depth and maps to the same App result. Consequence for R7's
    hosted matrix: editor composition is also what leaves editor source pending,
    so `testHostedReplaceRefusesWhileEditorSourceIsPending` and
    `testHostedReplaceRefusesWhileReloadIsSuspendedBehindPendingEditorSource`
    now assert App's §5.6 decision (`pendingEditorSource`, then
    `externalResolutionSuspended`) directly and that the command refuses
    `.markedText` first with zero effect and no authorization record; the first
    also refuses an isolated pending-source fence (no composition) through the
    production path with its §5.6 reason.
  - Bullet 3:
    `testHostedReplacementFieldReturnAndEscapeDeferToCompositionThenAFreshReturnReplacesOnce`
    calls the production field delegate with Return, Escape and Option-Return
    during composition (all declined to the input context), proves the bar's
    responder-chain Escape (`closeEditorFindBarFromExitCommand`) also refuses
    while the replacement field composes, commits the composition (the value is
    published once, nothing replaces), then a fresh Return through the real field
    editor replaces exactly once (one Undo restores the source; nothing else to
    undo), and Escape without composition closes the bar keeping the value.
  - Bullet 4:
    `testHostedMarkedTextBeginningDuringReplaceAllPlanningInvalidatesTheActionInEachOwner`
    starts Replace All from the real button, parks the off-main worker, begins
    composition in each owner, then releases it. Query and replacement field
    composition change no source, query or replacement generation, so only the
    live owner recheck at commit sees them: the result is `.markedText` with no
    writer activation. Native editor marked text also moves the editor selection,
    which PR G's preparation-only selection observer reports first (`.superseded`);
    either way no writer activation, mutation or undo occurs, and nothing fires
    after composition ends. EditorKit's own final editor check is
    `EditorReplaceBatchExecutorTests.testMarkedTextAppearingAfterPreparationRefusesBeforeAuthorizationOrUndo`.
  - Owner harness prepared for PR I (not run here): the editor owner keeps the
    §5.5 command,
    `cd Packages/EditorKit && PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter EditorReplaceActualIMEGateTests`;
    the two App-owned fields need an app-hosted opt-in run,
    `TEST_RUNNER_PLAINSONG_RUN_ACTUAL_IME=1 xcodebuild -project Plainsong.xcodeproj -scheme Plainsong test -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedActualIMEReplaceFieldOwners`,
    following the `PLAINSONG_RUN_ACTUAL_IME` TIS/CGEvent precedent. Neither
    test exists yet; PR I adds them, and bullets 5–6 stay open until the owner
    records a run.

### R7 — External reconciliation and indeterminate-write fencing

- [x] App owns a plain STTextView-free replacement authorization decision for
  the exact focused session; EditorKit consumes it without importing App or
  WorkspaceKit.
- [x] Command execution and pre-commit both check authorization; the final
  check, writer activation, and mutation have no suspension between them.
- [x] Pending external observation/prompt, deferred/active Reload or Keep Mine,
  partial coordinator convergence, workspace write fence, pending editor
  source, recovery-fenced missing/detached formerly-backed authority, and every
  indeterminate quarantine refuse replacement.
- [x] App authorization refusal leaves source, selection, ordinal, fields,
  undo, progress, navigation, and recovery authority unchanged. Later writer
  refusal may only perform documented authoritative convergence; it applies no
  replacement or queued intent.
- [x] A valid installed untitled/in-memory document is not blocked solely
  because it has no URL.
- [x] A fence appearing after planning drops the exact plan before any undo
  group starts.
- [x] Reload/Keep Mine completion triggers counter-only recomputation from the
  accepted source and requires a fresh explicit Replace.
- [x] Integration coverage includes a pending choice, suspended Reload,
  partial live-editor convergence, readable quarantine, and unavailable
  Check Again quarantine.
- PR D follow-up, decided in PR E: a write that is not applied leaves **no** undo
  step. STTextView registers an insert's undo group after it notifies the
  delegate; `EditorReplaceRejectedWriteUndo` observes the executor's own write
  and, only when the text-did-change notification shows the exact pre-write
  source at the pre-write revision in both the App snapshot and the native view
  (a rejected, restored publication), disables undo registration until the insert
  returns. No undo action is written or removed by hand; applied, reconciled, and
  unobservable writes register their native group as before. Ordinary typing is
  unchanged. Evidence:
  `EditorReplaceWriteOutcomeTests.testRejectedPublicationLeavesNoUndoStepAndKeepsPriorHistory`
  (the next Undo reverts the typing that preceded the refused Replace; undo
  registration stays balanced) and the undo assertions added to
  `testRejectedPublicationIsNotReportedAsReplaced`; with the guard disabled both
  fail.
- Evidence (hosted tests are in the app-hosted `PlainsongTests` bundle; the
  `EditorReplaceHosted*GateTests` files extend `EditorFindHostedGateTests` and
  mount production `WorkspaceWindow`s in designated key windows):
  - Decision and layering: `EditorReplaceAuthorizationAppTests`
    (`testEverySection56StateRefusesWithItsReasonAndAdvancesTheGeneration`: one
    reason per §5.6 state, including the in-flight read, indeterminate
    mutation, and missing-file prompt; `testDecisionIsBoundToTheExactSessionAndIsNotCanSave`;
    `testRestoredTextRecoverySessionIsRecoveryFenced`;
    `testCommitAuthorizationReEvaluatesLiveStateAndRecordsItsReason`);
    `EditorReplaceLayeringTests.testEditorKitImportsNeitherAppNorWorkspaceKit`
    and `testAppAndMarkdownCoreDoNotImportSTTextView`.
  - Two checks, one synchronous commit turn:
    `testHostedReplaceChecksAuthorizationAtValidationAndAgainAtCommit`
    (checkpoints `[.validation, .commit]`; the call returns with the mutation
    applied) and `testHostedFenceAppearingBeforeCommitRefusesAtTheCommitCheck`
    (a fence injected between validation and EditorKit's commit call, or set and
    cleared there, refuses with no undo group).
  - §5.6 matrix, each refused through the production path with the zero-effect
    snapshot (`EditorReplaceEffectSnapshot`: App and native source, revision,
    dirty, selection, Find session and query generation, find chrome, undo/redo,
    shared and pending navigation, and every recovery/quarantine/fence map):
    `testHostedReplaceRefusesWhileAnExternalChangeAwaitsAChoice`,
    `testHostedReplaceRefusesWhileReloadIsSuspendedBehindPendingEditorSource`,
    `testHostedReplaceRefusesAReadableIndeterminateWriteQuarantine`,
    `testHostedReplaceRefusesAnUnavailableCheckAgainQuarantine`,
    `testHostedReplaceRefusesDuringAWorkspaceMutationWriteFence`,
    `testHostedReplaceRefusesWhileEditorSourceIsPending`,
    `testHostedReplaceRefusesARecoveryFencedDetachedSession`,
    `testHostedReplaceWaitsForEveryLiveEditorToConvergeAfterReload` (partial
    convergence with two live installations). The in-flight inspection reason
    (`externalObservationPending`) is covered by
    `testEverySection56StateRefusesWithItsReasonAndAdvancesTheGeneration`.
  - Stricter than §5.6: an in-flight disk inspection (`externalDiskInspectionTasks`)
    refuses as `externalObservationPending`, before any conflict is known. A
    self-written save is recognized only inside that inspection, so every
    autosave's own file-system event opens a brief refusal window that ends when
    the inspection adopts the saved bytes. **Note for PR H / R10:** Replace UI and
    XCUITests must expect this transient refusal right after an autosave (present
    it as a momentary blocked state and retry on a fresh explicit action, or wait
    for the inspection to settle) rather than treat it as a failure.
  - Writer refusal after authorization:
    `testHostedWriterRefusalAfterAuthorizationOnlyConverges` (the stale view
    converges to App's source, no replacement or undo group, Find recounts
    counter-only, then a fresh Replace succeeds).
  - Untitled: `EditorReplaceAuthorizationAppTests.testInstalledUntitledDocumentIsAllowedThroughTheProductionPath`
    (no URL, no identity, `canSave == false`, replaced through App → EditorKit;
    only an explicit fence refuses it).
  - Supersession: `testHostedFenceAppearingAfterPlanningDropsThePlanBeforeAnyUndoGroup`
    (a write fence set and cleared after planning: the decision is `.allowed`
    again, yet the plan fails with no undo group);
    `EditorReplaceAuthorizationAppTests.testAuthorityGenerationAdvancesOnLifecycleFocusAndBarTransitions`
    and `testTypingSupersedesAStampWithoutTouchingTheGeneration` (edits
    supersede through the monotonic session revision, with no keystroke-path
    work); `EditorReplaceCommandDispatcherTests.testSelectionChangeAfterPlanningDropsTheCommand`.
    Hooks cover the fence and prompt maps the decision reads and editor
    installations; `sessionStateURL`'s inputs (`anchoredSessionFileBindings`,
    `unanchoredManagedSessionOwnershipProofs`, `indeterminateSessionWriteContexts`)
    and `externalResolutionIntentCaptures` are not hooked and are covered by the
    rekey notification, the write-fence `didSet`, and the live evaluation at
    commit. PR G adds a preparation-only native-selection observer that advances
    this same authority generation, so selection A→B→A drops the batch even if
    the final editor stamp is equal. Existing App focus/key-window generations
    fence their ABA transitions. Named hosted supersession tests prove both;
    no permanent per-keystroke or selection-path hook is added.
  - Resolution: `testHostedReloadCompletionRecountsCounterOnlyAndRequiresAFreshReplace`,
    `testHostedKeepMineCompletionRevalidatesAndRequiresAFreshReplace` (Keep Mine
    keeps identity, revision, and source, so the retained session is the recount:
    no second scan and no shared-channel publication, as F4b requires),
    `testHostedKeepMineCompletionHookRecountsAStaleFindBinding`, and
    `testHostedReplaceWaitsForEveryLiveEditorToConvergeAfterReload`. The hook's
    generation advance cannot be isolated in a hosted test: choosing Keep Mine or
    Reload already sets `deferredExternalChangeResolutions`, and finalization
    clears the resolution maps, and both advance the generation. Its counter-only
    revalidation is isolated by `testHostedKeepMineCompletionHookRecountsAStaleFindBinding`,
    which leaves Find bound to an older source (a synthetic desync, since nothing
    on the Keep Mine path notifies Find) and fails with
    `editorReplaceExternalResolutionDidComplete` disabled. For Reload the
    apply-time `notifyEditorFindExternalContentDidReplace` already recounts, so the
    hook's recount is a no-op there.
  - Delivery and key-window/installation proof:
    `testHostedReplaceFromTheQueryFieldUsesTheFindFallback` (drives both
    fallback branches through Find's `commandContextOverride` seam, so it does not
    exercise the production eligibility check),
    `testHostedReplaceFromFindChromeUsesTheProductionFallbackCheck` (no override:
    Find's real `isEditorFindCommandContextActive()` chrome-focus branch, with
    only the key-window number stubbed through `keyWindowNumberOverride`; the
    `NSApp.keyWindow` query-field branch stays unexercised because only designated
    key status is controlled, not the host's real key window),
    `testHostedReplaceReachesOnlyTheKeyWindowsInstallation` (no-key refusal preserves
    both installations' zero-effect snapshots; an installed key-window test override
    is authoritative even when it returns nil, so the XCTest host's real key window
    cannot enter the fixture),
    `EditorReplaceCommandDispatcherTests.testNilKeyWindowOverrideRefusesBeforeAuthorization`
    (stamp capture, responder delivery, and fallback refuse before authorization),
    `EditorReplaceCommandDispatcherTests` (responder chain, no main-window
    fallthrough, background and unregistered installations, stamp capture), and
    PR D's `EditorReplaceSingleReplaceAppTests` now driven through
    `AppState.performEditorReplace` instead of `performSingleReplace`.
  - Negative controls: with the authority-input hook disabled, the two fence
    supersession tests fail and stale plans commit; with the completion hook
    disabled, `testHostedKeepMineCompletionHookRecountsAStaleFindBinding` fails.

### R8 — UI, menu, focus, and accessibility

- [x] Existing find row behavior and IDs remain compatible; disclosed second
  row owns replacement field, Replace, Replace All, progress, Cancel, blocked,
  and overflow identifiers.
- [x] A replacement over 256 UTF-16 code units shows an explicit field error
  and disables both replacement actions; empty replacement remains valid.
- [x] Edit menu adds Find and Replace…, Replace, Replace All; v1 adds no global
  shortcut and preserves Format Table `⌥⌘F`.
- [x] `⌘F` focuses/selects query without collapsing Replace; `⌘E` changes only
  query; query-focus intents and `⇧⌘F` cancel pre-commit Replace All, while
  `⇧⌘F` supersedes but never consumes editor-find receipts.
- [x] Find and Replace… uses the existing key-window query focus receipt;
  Tab/click enters replacement without a competing async focus token.
- [x] Replace/Replace All menus are eligible from either owned field editor
  only while the bar is visible and replacement row expanded; close/collapse
  cancels planning and hidden retained text cannot execute.
- [x] Menu commands target only the installed editor in the key window;
  background/remounted bars cannot replay focus or mutation.
- [x] Full Keyboard Access can invoke every bar control; progress, blocked, and
  overflow states are spoken and not color-only.
- [x] Escape closes/cancels only after marked-text refusal; query and
  replacement values follow the documented file/workspace lifecycle; pending
  focus/reports are superseded without resetting monotonic receipt high-water
  marks.
- [ ] Owner Full Keyboard Access smoke (added by PR H): with the system setting
  on, Tab reaches and Space invokes the disclosure, both fields, Replace,
  Replace All and Cancel in a Debug build, recorded beside the F6/F7 owner
  smoke. In-process tests cannot turn the system setting on: AppKit ignores
  Space on a focused button without it, and SwiftUI builds no accessibility tree
  without an assistive client.
- Evidence (PR H; hosted methods run as `EditorFindHostedGateTests` on production
  `WorkspaceWindow`s whose key status is designated; production key-window
  eligibility runs with no `commandContextOverride`, only *which* window is key is
  designated through `EditorSelectionProbe.keyWindowOverrideForTesting` and the
  new `EditorFindHost.keyWindowOverride`; row controls are clicked with AppKit
  `performClick` and fields driven through their real field editors):
  - IDs and row: `testHostedReplaceRowKeepsFindRowIdentifiersAndOwnsEveryReplaceIdentifier`
    pins the nine Find-row identifiers, proves the collapsed bar mounts no
    replacement control, expanding never remounts the query field, and the row
    owns the field, Replace and Replace All (Cancel only while preparing). Progress
    and Cancel are read from the mounted views in
    `testHostedEscapeInTheReplacementFieldClosesCancelsAndRetainsEverythingForReopen`;
    blocked and overflow in
    `testHostedOverflowAndBlockedStatesAreSpokenTextAndRefuseWithZeroEffect`; the
    result label in `testHostedReplaceAllButtonSpeaksChangedOfTotalAndNoChanges`.
    Every existing `EditorFind*` hosted suite passes unchanged.
  - Field validation: `testHostedReplacementOverLimitShowsFieldErrorAndDisablesBothActionsWhileEmptyStaysValid`
    (258 units from 129 surrogate pairs, a pasted line break, exactly 256 units,
    and empty deleting the match), `EditorReplaceUIStateTests.testReplacementValueEditsBumpOnlyTheReplacementSeamAndValidateOnce`
    and `EditorReplaceStatusTextTests.testFieldErrorsCoverLengthAndLineBreaksAndEmptyIsValid`.
    `testHostedReplaceButtonAndReturnReplaceThroughRealControlsAndKeepFieldFocus`
    proves `$1\n` stays literal, Return replaces without taking focus from the
    field, and each Replace is one undo step.
  - Menu: `testEditMenuAddsFindAndReplaceReplaceAndReplaceAllWithoutShortcuts`
    reads the hosted app's real `NSApp.mainMenu`: each item once, empty key
    equivalents, Find and Replace… after Find…, Replace items after Use Selection
    for Find, and Format ▸ Format Table still `⌥⌘F`.
  - Existing commands: `testHostedCommandFRefocusesAndSelectsTheQueryWithoutCollapsingAndCancelsThePlan`,
    `testHostedUseSelectionForFindAndFindNextPreviousLeaveTheReplacementAndSourceAlone`
    (⌘E changes only the query and focuses nothing; ⌘G / ⇧⌘G never mutate) and
    `testHostedShiftCommandFCancelsThePlanAndSupersedesFindFocusWithoutConsumingReceipts`
    (through `PlainsongWorkspaceSearchKeyAction`, the ⇧⌘F production action).
  - Find and Replace…: `testHostedFindAndReplaceUsesTheQueryReceiptAndTabReachesReplacementWithoutAToken`
    spends the existing query receipt with select-all; Tab (AppKit's key-view
    loop) and Shift-Tab move between the fields and a click focuses the
    replacement field, with `focusRequestID` unchanged and no retry stealing focus.
  - Eligibility matrix: `testHostedReplaceMenuEligibilityMatrixReachesOnlyTheExpandedKeyWindowRow`
    (bar hidden, row collapsed through the real disclosure, query field, replacement
    field, focus elsewhere; each ineligible case has a zero-effect snapshot),
    `testHostedReplaceMenuFromABackgroundWindowCannotReachAnotherWindowsRow`,
    `testHostedRemountedBarCannotReplayAFocusTokenOrAPreparingPlan` (a remounted
    bar's owner registration supersedes the preparing plan, and its query field
    never replays the spent receipt), `testHostedCollapseThroughTheDisclosureCancelsThePlanAndHidesTheRetainedValue`
    (the real collapse seam PR G left, now driven from the disclosure) and
    `EditorReplaceUIStateTests.testCollapseAndExpandAreTheAuthoritySeamAndCollapseKeepsTheValue`.
  - Keyboard/assistive access and speech:
    `testHostedRowControlsAreFocusableRespondersAndPressingFocusedCancelCancelsThePlan`
    (each owned control is a real responder that keeps the menus eligible without
    advancing the authority generation, its accessibility press runs it, and
    focusing Cancel keeps the plan alive until pressing it returns `.cancelled`).
    All row states are text in owned AppKit labels whose accessibility label is
    the same text, with decorative symbols hidden from accessibility; results,
    refusals, blocked, overflow and the start of preparation are also posted as
    accessibility announcements (`lastReplaceAnnouncement` asserts the spoken
    text). `EditorReplaceStatusTextTests` maps every plain PR D–G result to one
    sentence, including the transient `externalObservationPending` ("try again in
    a moment", shown as blocked, not as a failure) and a distinct Cancel.
  - Escape and lifecycle: `testHostedReplacementFieldReturnAndEscapeDeferToCompositionThenAFreshReturnReplacesOnce`,
    `testHostedEscapeInTheReplacementFieldClosesCancelsAndRetainsEverythingForReopen`,
    `testHostedFileSwitchKeepsTheExpandedRowAndValuesAndDropsThePlanAndMessage`,
    `testHostedExternalReloadKeepsValuesAndExpansionCancelsProgressAndRecountsFirst`
    (a clean reload, then rekey, then a fresh Replace All only after recount), and
    `EditorReplaceUIStateTests` for Escape/Done, no document (closed and collapsed,
    values kept, pending focus superseded, chrome reports cleared), workspace close
    (both values cleared, receipt high-water marks kept) and Reload / Keep Mine
    completion clearing a stale blocked message.
  - Typing path: `testHostedEditorTypingWithTheRowOpenTouchesNoReplaceGenerationOrRowState`
    types into the editor with the row open and the replacement field mounted; the
    authority generation, replacement generation, status serial and row state do
    not move. Replacement-field edits reach App only through that field's own
    delegate, never through the editor's text path. The row is an `Equatable`
    view over a small value model and does not observe `AppState`, so an
    unrelated publish costs one value comparison and never re-evaluates the row
    or updates its AppKit views; validation runs once per value edit, not in a
    view body. This is structural evidence; the idle-machine typing measurement
    with the row open belongs to R9.

### R9 — `large-1mb.md` Replace All + §12 typing latency

- [ ] Measure a production-shaped exact Replace All on
  `Fixtures/large-1mb.md` through App authorization, EditorKit writer
  activation, native undo, post-write rescan, and enabled layout modes.
- [ ] One measured shape combines an exact near-10,000 non-truncated set with
  the 256-code-unit v1 replacement ceiling.
- [ ] Record at least three Debug and three Release runs, exact match count,
  replacement lengths, commit SHA, machine/toolchain, and reproduction command
  in `docs/perf-log.md`.
- [ ] With the replacement row open and a near-ceiling plan preparing/
  cancelling, ordinary typing remains under the hard §12 `< 16 ms` budget.
- [ ] After Replace All, Undo, and Redo, the same typing probe remains under
  `< 16 ms`; no retained task/progress/presentation work leaks onto keystrokes.
- [ ] Record end-to-end preparation, synchronous commit, rescan, and
  presentation timings plus Cancel-to-task-drain. Freeze named local batch and
  cancellation budgets from measured Debug medians; never invent/widen one to
  rescue a failure.
- [ ] Wall-clock budgets are hard locally and informational on hosted CI under
  risk R15 (`docs/risk-register.md`); deterministic source/undo/fence
  assertions remain hard everywhere.
- Evidence: _open_

### R10 — Hosted acceptance and XCUITest

- [ ] App-container current-document fixture; predicate waits; no `NSOpenPanel`
  automation or AppState injection.
- [ ] Replace one with unequal UTF-16 lengths; post-write counter/current
  follows §5.2 and no hidden second matcher appears.
- [ ] Replacement containing query shows recomputed remaining hits without
  recursive growth; explicit Next performs the wrap.
- [ ] Truncated single Replace (including the 10,000th retained hit and a
  replacement containing the query) never scans beyond the retained prefix.
- [ ] Literal-identical single/all and mixed-identical Replace All exercise
  zero-write advancement, “No changes,” and “Changed X of Y matches.”
- [ ] Source-changing Replace All exact set is one Undo/Redo; an all-identical
  set creates none; overflow refuses; Cancel before commit leaves source
  unchanged.
- [ ] Source-only, source+preview, and Experimental WYSIWYG cover folded
  delimiter, link destination, and image region.
- [ ] Pending Reload/Keep Mine and indeterminate quarantine visibly disable/
  refuse both commands and recover only after explicit resolution.
- [ ] Dual-window and Full Keyboard Access routes mutate only the key window's
  installed document; `⌘F`, `⌘E`, and `⇧⌘F` focus contracts remain green.
- Evidence: _open_

## 9. Performance gate

| Step | Rule |
|---|---|
| Prerequisite | Start after the in-flight Find latency PR lands; reuse its production controller/typing harness rather than creating a rival baseline. |
| Fixture | `Fixtures/large-1mb.md`, exact source copy, production App authorization + EditorKit writer path. |
| Required stress | Exact high-count/non-truncated Replace All, cancellation before commit, one commit, one rescan, Undo, Redo, source-only/source+preview/Experimental WYSIWYG. |
| Typing gate | `< 16 ms` remains hard while the bar is open, while preparation is active, and after batch/undo/redo. Any regression rejects the PR regardless of Replace output correctness. |
| Measurement | At least three Debug + three Release runs; record medians and raw runs in `docs/perf-log.md`. |
| Batch/cancel budgets | Measure end-to-end batch phases and Cancel-to-task-drain first; freeze named local bounds from Debug medians. Do not invent or widen a number to make an implementation pass. |
| CI | Wall-clock informational on hosted CI under risk R15 (`docs/risk-register.md`); exact source, counts, undo, stale-drop, and fence assertions hard everywhere. |

## 10. Owner decisions before product UI

Core semantics above are fixed for this gate set. Three policy choices remain
available for explicit owner override at the deadlines below:

| Question | Gate default unless owner changes it |
|---|---|
| Is 256 UTF-16 code units the right v1 replacement-field ceiling? | **Yes.** It matches the existing literal query scale and bounds 10,000-match growth to 2,560,000 code units. Any override must land before PR C with a named measured alternative; unbounded replacement is not an option. |
| May v1 replacement contain literal newlines? | **No.** Keep one owned single-line field; reject literal line breaks; do not invent `\n` escape expansion. A multiline editor is a separate UI/IME scope. |
| Should a new global shortcut replace the existing Format Table `⌥⌘F` binding? | **No.** Preserve §6.4 and ship Find and Replace… / Replace / Replace All as discoverable menu and bar actions without new global shortcuts. |

R0 is not an owner taste decision: its observed GO/NO-GO result determines
whether Replace All is technically feasible under the fixed one-undo and
writer-authority contract.

## 11. Explicit non-goals

- Regex.
- `$1`-style capture/template expansion.
- Workspace-wide replace.
- Selection-scoped replace.
- Preview-pane replace.
- Changing `TextSearchEngine` semantics.
- Multiline replacement UI or escape-sequence language in v1.
- Replacing ignored/non-Markdown workspace files.
- Auto-repairing Markdown, URLs, or image syntax after replacement.
- A second matching, navigation, selection, source-publication, or undo system.

## 12. Sign-off

| Role | Responsibility |
|---|---|
| Implementer | Start with R0; named evidence for every checked R-gate; preserve layering, authority, and exact local-versus-hosted performance claims. |
| Owner | Decide whether to override the three §10 defaults; run real Zhuyin/Pinyin R6 evidence; decide product redesign only if R0 is NO-GO. |
| Maintainer | Review/squash-merge each PR after green CI. Never permit a self-merge or direct push to `main`. |
