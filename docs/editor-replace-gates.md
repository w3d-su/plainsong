# In-Document Replace — Gate Specification

> **Status: R0 is GO on Candidate B1 (minimal enclosing range).** Spec PR A (#100)
> remains merged. This mechanism-spike PR does not ship user-facing Replace.
> R1–R10 stay open. Candidate A is one native undo group but publishes once per
> match, so it is NO-GO for Replace All. Candidate B2 works as a fallback and is
> not chosen while B1 preserves source, undo, dirty, and presentation.
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
| **D — source-only single Replace** | EditorKit current-match executor through writer activation, exact applied selection, native undo, replacement-aware publication, one rescan, and ordinal continuation. No App lifecycle policy, visible UI, or WYSIWYG overlap work. | R2 and R3 integration |
| **E — App authorization/lifecycle** | Plain App commit authorization, external/reload/quarantine fences, monotonic plan supersession, untitled authority, key-window/install proof, and hosted lifecycle matrix. No new product chrome. | R7 |
| **F — Experimental WYSIWYG** | Single-Replace raw-source reveal/suspend/reapply for folded delimiter, hidden link destination, and image region; source+preview publication. | R5 single-Replace/source-preview bullets; R5 remains open |
| **G — Replace All pipeline** | R0-approved executor, bounded off-main cancellable plan/progress, stale-drop, output/ceiling refusal, changed/total reporting, one rescan, mapped anchor, one undo, and one batch WYSIWYG suspend/reapply. | R4, R5 batch bullet, and Replace All portions of R2/R3 |
| **H — product UI + deterministic IME** | Expand existing bar; owned replacement field; menu/responder routing and visibility eligibility; focus-token arbitration; blocked/progress/accessibility states; deterministic marked-text tests. | R6 deterministic half and R8 |
| **I — acceptance/performance** | XCUITest, owner-run real Zhuyin/Pinyin boundary harness, and `Fixtures/large-1mb.md` Replace All/cancellation/typing-latency measurements. | R6 owner half, R9, R10 |

Before declaring an implementation PR done: relevant package/hosted tests,
`make format`, `make lint`, `make test`, `make build`, and
`git diff --check`. PR bodies list gates actually closed and those still open.

## 8. Gates

All boxes intentionally start unchecked.

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
  Evidence: `testCandidateB1PublishesOnceForTheEnclosingRange` — 1 writer
  activation, 1 authorized native edit, 1 publication.
- [x] Candidate B2 is measured separately, and only if B1 fails: one
  full-document native replacement.
  Evidence: `testCandidateB2PublishesOnceForTheFullDocument`. B1 did not fail;
  B2 remains an unused fallback.
- [x] One Undo restores literal UTF-16-code-unit-exact source, selection, dirty
  baseline, and presentation for the entire batch; no second Undo is needed
  for another match.
  Evidence: `testMinimalEnclosingRangeIsOneUndoAndRedo` (source/selection/dirty);
  `EditorReplaceBatchSpikeWYSIWYGTests.testMinimalEnclosingRangeUndoRestoresFoldPresentation`.
- [x] One Redo reapplies the exact whole batch.
  Evidence: `testMinimalEnclosingRangeIsOneUndoAndRedo`.
- [x] Seed prior typed/coalesced input first: Replace All must not merge with
  it; the next Undo after undoing Replace All reaches the prior input.
  Evidence: `testReplaceAllDoesNotMergeWithPriorTyping`.
- [x] Record activation, native edit, source publication, revision, and
  presentation-apply counts. One undo with N intermediate publications is not
  sufficient evidence.
  Evidence: A = N edits / N publications (NO-GO); B1 = 1/1 (GO); B2 = 1/1
  (fallback). Presentation applies stay outside the mutation (one apply after).
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
  construction, main-thread, allocation, and typing impact.
  Evidence: 8,921 matches; construction ≈ 4.5 ms; B1 commit ≈ 42 ms; post-batch
  `insertText` ≈ 0.5 ms; planned UTF-16 length 3,314,896.
- [x] Record GO candidate or NO-GO. If no allowed candidate passes, Replace All
  remains deferred and this design changes before any product UI claims it.
- Evidence: **GO — Candidate B1.** No user-facing Replace. PR C may consume the
  B1 construction helper; product mutation stays behind later PRs.

### R1 — One literal match semantics

- [ ] Replacement planner consumes only `EditorFindSession` matches from
  existing `TextSearchEngine`; no second matching path.
- [ ] Smart/sensitive/insensitive, whole-word, invalid query, canonical
  equivalence, and non-overlap agree exactly with Find.
- [ ] Match length is taken from returned UTF-16 range, never query length.
- [ ] Empty replacement deletes; `$1`, `\1`, and `\n` are literal, not
  templates/escapes.
- [ ] Replacement accepts at most 256 UTF-16 code units; multiline/over-limit
  values are explicitly invalid without changing search semantics.
- [ ] Source-identical comparison is literal UTF-16 code-unit equality, not
  canonically equivalent Swift `String ==`.
- [ ] Regex input or mode cannot be enabled by the Replace surface.
- [ ] Plans cover the whole current installed document/session only; no
  selection-scoped mode, workspace enumeration/fan-out, or workspace-wide
  replacement path exists.
- Evidence: _open_

### R2 — Exact current-match mutation through writer activation

- [ ] Replace requires exact identity/revision/query generation, current match,
  installed state, and applied selection range.
- [ ] A not-yet-applied match navigates/reveals only; it does not mutate or
  queue a later mutation.
- [ ] The successful character edit runs only inside the WS3B
  writer-authorized synchronous closure and uses native insertion.
- [ ] `STTextFinderClient.replaceCharacters`, direct `textStorage` character
  writes, and App binding assignment are absent.
- [ ] App and MarkdownCore import/name no STTextView type; concrete editor
  mutation remains confined to EditorKit.
- [ ] No new Swift/npm dependency or project-target change is introduced.
- [ ] Failed App authorization has zero source/selection/ordinal/progress/undo
  effect. Failed writer preflight may only synchronize stale native source and
  clamp selection under its existing contract; it performs no replacement,
  opens no replacement undo group, and queues no retry.
- [ ] One source-changing Replace is one native undo step and preserves prior
  undo history; the literal-identical path creates no undo entry.
- Evidence: _open_

### R3 — Post-write rescan and ordinal

- [ ] One source-changing Replace publishes authoritative post-write
  text/revision, then performs exactly one full existing-engine rescan.
- [ ] Replacement-aware publication consumes that revision once, suppressing/
  coalescing the same revision's ordinary `.edit` Find schedule while all other
  document-text consumers still receive normal publication.
- [ ] `resumeUTF16 = oldStart + replacementUTF16Length`; new current is the
  first retained recomputed start at/after it.
- [ ] No automatic wrap; no later retained match means current `nil` /
  `0 / total` until explicit Next.
- [ ] Replacement-created matches are counted but starts inside the inserted
  span are skipped for automatic continuation.
- [ ] Boundary-created/destroyed whole-word and canonical-equivalent matches
  come only from the full rescan, not delta-patched ranges.
- [ ] A literal-identical single Replace performs no writer/revision/undo/
  rescan, but advances within the unchanged retained session without implicit
  wrap.
- [ ] A no-later source-changing or literal-identical Replace stores
  `caretAnchorUTF16 = resumeUTF16` / old match end respectively and collapses
  selection there before explicit Next/Previous uses retained-set wrap.
- [ ] A truncated single Replace, including replacement containing the query
  and the 10,000th retained match, continues only within the recomputed retained
  prefix; it never starts an unbounded second scan.
- [ ] Replace All consumes its pre-write set once, rescans once, and leaves
  current `nil` with the mapped post-batch selection as `caretAnchorUTF16`;
  replacement-created hits are never recursively replaced.
- Evidence: _open_

### R4 — Replace All ceiling, cancellation, and progress

- [ ] Exact non-truncated sets through 10,000 are eligible; 10,001 overflow
  refuses with explicit non-color-only text and zero mutation.
- [ ] A stale/missing/recomputing session refuses; it does not retain a pending
  batch intent.
- [ ] Final-source/plan preparation runs off-main, checks cancellation after at
  most 64 matches or 65,536 copied UTF-16 code units (whichever comes first),
  and emits at most 100 monotonic progress updates.
- [ ] Replacement is at most 256 UTF-16 code units. Checked projected-length
  math bounds growth to 2,560,000 code units; invalid length or integer
  overflow refuses before allocation/writer activation. No recoverable Swift
  allocation-failure promise is made.
- [ ] A monotonic action ID and authority/lifecycle generation fence the exact
  identity/revision/query/options/replacement generation, current ordinal,
  applied selection, key window, and editor installation.
- [ ] Query/options/replacement changes, edits/rebinds, navigation/selection,
  key-window/remount, workspace-search focus/activation, close/collapse,
  Cancel, or a new fence bumps a monotonic token and supersedes the plan even
  if values later return.
- [ ] Immediately before writer activation, with no suspension before
  mutation, commit rechecks the full tuple, App authorization, and marked text
  in editor/query/replacement fields.
- [ ] Commit uses only the R0-approved single-undo mechanism and is explicitly
  non-cancellable once its synchronous native closure starts.
- [ ] Cancel before commit leaves exact source, selection, ordinal, undo, and
  presentation unchanged; task cancellation is observed at the deterministic
  R4 work-chunk boundaries.
- [ ] All-literal-identical batches report “No changes” with no writer,
  revision, undo, rescan, selection, or ordinal change. Mixed batches change
  only differing ranges in one undo and report “Changed X of Y matches.”
- Evidence: _open_

### R5 — Experimental WYSIWYG raw-source replacement

- [ ] Folded delimiter overlap reveals the owning region, replaces the exact
  raw-source UTF-16 span, and performs no Markdown repair.
- [ ] Folded link-destination overlap reveals the whole link, replaces only
  the raw match, and performs no URL normalization.
- [ ] Image overlap removes/suspends projection, replaces exact raw image
  source, and never mutates projected U+FFFC/U+200B text.
- [ ] Valid post-write constructs may fold/thumbnail again only after reparse;
  invalid constructs remain raw and editable.
- [ ] Replace All suspends/reapplies presentation once per batch, not once per
  match; backing source, copy, selection, and accessibility remain canonical.
- [ ] Source-only and source+preview publish through the normal document/
  preview path; no preview DOM mutation.
- Evidence: _open_

### R6 — Marked text + real Zhuyin/Pinyin boundaries

- [ ] Deterministic tests refuse Replace/Replace All while marked text exists
  in the editor, query field, or replacement field.
- [ ] Refusal performs no navigation/reveal, authorization/preflight, undo,
  progress, ordinal change, or queued post-composition action.
- [ ] Replacement-field Return and Escape defer to the input context while
  marked text exists; after composition a fresh explicit action is required.
- [ ] Marked text beginning in any of the three owners during Replace All
  planning invalidates the action at final pre-commit recheck, with no queued
  post-composition mutation.
- [ ] Owner-run real macOS Zhuyin **and composition-capable Pinyin** harness
  covers source mode and Experimental WYSIWYG at plain text, folded delimiter,
  hidden link destination, and image-region boundaries.
- [ ] Owner evidence records TIS input-source IDs, real event route, no skipped
  composition, exact committed source/caret, and exactly one mutation after a
  fresh post-composition Replace.
- Evidence: _open — synthetic coverage does not close owner-run item_

### R7 — External reconciliation and indeterminate-write fencing

- [ ] App owns a plain STTextView-free replacement authorization decision for
  the exact focused session; EditorKit consumes it without importing App or
  WorkspaceKit.
- [ ] Command execution and pre-commit both check authorization; the final
  check, writer activation, and mutation have no suspension between them.
- [ ] Pending external observation/prompt, deferred/active Reload or Keep Mine,
  partial coordinator convergence, workspace write fence, pending editor
  source, recovery-fenced missing/detached formerly-backed authority, and every
  indeterminate quarantine refuse replacement.
- [ ] App authorization refusal leaves source, selection, ordinal, fields,
  undo, progress, navigation, and recovery authority unchanged. Later writer
  refusal may only perform documented authoritative convergence; it applies no
  replacement or queued intent.
- [ ] A valid installed untitled/in-memory document is not blocked solely
  because it has no URL.
- [ ] A fence appearing after planning drops the exact plan before any undo
  group starts.
- [ ] Reload/Keep Mine completion triggers counter-only recomputation from the
  accepted source and requires a fresh explicit Replace.
- [ ] Integration coverage includes a pending choice, suspended Reload,
  partial live-editor convergence, readable quarantine, and unavailable
  Check Again quarantine.
- Evidence: _open_

### R8 — UI, menu, focus, and accessibility

- [ ] Existing find row behavior and IDs remain compatible; disclosed second
  row owns replacement field, Replace, Replace All, progress, Cancel, blocked,
  and overflow identifiers.
- [ ] A replacement over 256 UTF-16 code units shows an explicit field error
  and disables both replacement actions; empty replacement remains valid.
- [ ] Edit menu adds Find and Replace…, Replace, Replace All; v1 adds no global
  shortcut and preserves Format Table `⌥⌘F`.
- [ ] `⌘F` focuses/selects query without collapsing Replace; `⌘E` changes only
  query; query-focus intents and `⇧⌘F` cancel pre-commit Replace All, while
  `⇧⌘F` supersedes but never consumes editor-find receipts.
- [ ] Find and Replace… uses the existing key-window query focus receipt;
  Tab/click enters replacement without a competing async focus token.
- [ ] Replace/Replace All menus are eligible from either owned field editor
  only while the bar is visible and replacement row expanded; close/collapse
  cancels planning and hidden retained text cannot execute.
- [ ] Menu commands target only the installed editor in the key window;
  background/remounted bars cannot replay focus or mutation.
- [ ] Full Keyboard Access can invoke every bar control; progress, blocked, and
  overflow states are spoken and not color-only.
- [ ] Escape closes/cancels only after marked-text refusal; query and
  replacement values follow the documented file/workspace lifecycle; pending
  focus/reports are superseded without resetting monotonic receipt high-water
  marks.
- Evidence: _open_

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
