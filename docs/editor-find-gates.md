# In-Document Find (⌘F) — Gate Specification

> **Status: SPEC ONLY (PR A). No behavior change. All gates F0–F9 are open.**
> This document is the blocking gate list for shipping focused-editor find. Precedent:
> PR #45 (`docs/wysiwyg-release-checklist.md`), link-folding (`docs/link-folding-gates.md`),
> and image-thumbnail (`docs/image-thumbnail-gates.md`) were spec-first before
> implementation. Implementation lands in PRs B–D below; check a gate box only with
> named-test or owner-recorded evidence in the same commit that claims it.

Created 2026-07-27 as Phase 3 Goal 14 after WS3C/WS4A landed workspace search (⇧⌘F).
See `agent.md` §6.4 (shortcuts), §12 (performance), §17 (layering / collaboration),
`docs/workspace-search-plan.md` §4.1 (MarkdownCore search model) and §4.4 (App/editor
navigation), and the Decision Log entry that freezes the engine choice.

## 1. Outcome

Ship Typora-class in-document find for the focused editor pane:

- `⌘F` toggles a find bar owned by the focused editor in the key window
  (open when closed; close when open — see §5.1).
- `⌘G` / `⇧⌘G` move to next / previous match with wrap-around at both ends
  (Typora behavior; agent.md §17.12).
- `⌘E` uses the current selection as the find pattern (when non-empty and valid).
- Escape closes the find bar and returns focus to the editor.
- Match counter shows current ordinal / total, with a distinct truncated state when
  the fixed match limit is hit (§5.1).
- Case-sensitivity and whole-word toggles match the workspace-search model
  (smart/sensitive/insensitive + Unicode whole-word).
- Navigation selects and reveals exact UTF-16 ranges through the existing
  `EditorNavigationRequest` / `EditorNavigationCommand` path — never a second
  selection/scroll channel.
- Find **never mutates source text**. Selection and reveal only.

Workspace search (`⇧⌘F`) remains independent. Neither feature's focus receipt may
consume the other's token.

## 2. Baseline: what ⌘F does today (code-verified table; runtime path open)

Empirical code inspection on the PR A tip (not a physical-keyboard run, and not a
live Edit-menu run):

| Observation | Evidence |
|---|---|
| STTextView ships a full `NSTextFinder` stack | `STTextView` init constructs `textFinder`, `STTextFinderClient`, and `STTextFinderBarContainer`; `performFindPanelAction` / `performTextFinderAction` forward to `textFinder.performAction` (`STTextView+Find.swift`). |
| `MarkdownSTTextView` does not override find | EditorKit subclass never touches `textFinder`, find actions, or the bar container. |
| Editor is hosted in `NSScrollView` | `MarkdownTextView.makeNSView` uses `MarkdownSTTextView.scrollableTextView()`, so the bar container has a scroll view to attach to. |
| Plainsong does not claim `⌘F` | `PlainsongCommands` claims `⇧⌘F` (Toggle Workspace Search) and Format Table is `⌥⌘F`. No Edit ▸ Find items are declared by the app. |
| Carbon hot key matches exact `cmdKey\|shiftKey` | `PlainsongMenuKeyBinding` / `PlainsongApplication` register only ⇧⌘F; plain ⌘F is intentionally unclaimed (Decision Log 2026-07-22). |
| If a system Find menu item reaches the first responder | AppKit Find actions use `performTextFinderAction:` / `performFindPanelAction:`; STTextView implements those selectors. **Whether SwiftUI synthesizes an Edit ▸ Find item for this app is not in-repo and is not established by reading source.** |

**Runtime hypothesis (not code-verified):** when the editor is first responder, a
reachable system or AppKit Find path may deliver `performTextFinderAction:` into
STTextView's built-in finder.

**PR B precondition — verify the hypothesis before any production find code:**

1. Launch the Debug app.
2. Open the Edit menu and look for a Find submenu / Find… item.
3. Focus the editor, press physical `⌘F`, and record what happens (find bar appears,
   nothing, beep, other).
4. Record the same under **ABC** and **Zhuyin** as part of F0.

Then branch explicitly:

| Outcome | Consequence |
|---|---|
| **(a)** A reachable built-in path exists | This work **replaces** it. The PR that ships the Plainsong replacement UI (**PR C**) must disable the built-in finder in the **same** PR so two find UIs cannot coexist. PR B must **not** remove the existing entry point (see §5.3 #6 and §7). |
| **(b)** No reachable path exists | There is nothing to replace. “Disable the built-in finder” is a no-op. No PR body may claim a replacement. |

F0 is a **blocking spike** (I0-shaped; see §7 / §8 F0): it decides the delivery
mechanism before PR C is authored. Synthetic `NSEvent`s and XCUITest input are
**not** F0 evidence (Decision Log 2026-07-22).

## 3. Engine decision (fixed)

**Use MarkdownCore `TextSearchEngine`. Do not adopt `NSTextFinder` as the find engine.**

| | |
|---|---|
| **Choice** | Pure `TextSearchEngine.matches(in:query:limit:previewContextGraphemes:)` for match lists; session ordinal / next-previous / wrap in MarkdownCore; EditorKit search controller debounces, runs off-main, cancels, and fences by document revision; navigation only via `EditorNavigationRequest` / `EditorNavigationCommand`. |
| **Why** | (1) Identical literal match semantics to ⇧⌘F workspace search (smart/sensitive/insensitive, Unicode whole-word, 256 UTF-16 pattern cap, newline-containing patterns rejected, UTF-16 `NSRange`, 1-based lines, bounded previews). (2) Reuses the already-gated exact-range navigation (WS3A). (3) A later replace feature must go through the WS3B writer-activation path rather than `NSTextFinder`'s own mutation path (`STTextFinderClient.replaceCharacters`). |
| **Rejected** | Shipping on STTextView's built-in `NSTextFinder` bar. |
| **Honest cost of rejection** | Free native find-bar UI, system Find menu integration, and incremental-search chrome. We pay for a custom bar, menu wiring, and highlight-all preservation. That cost is accepted so match semantics, navigation, and future replace stay inside Plainsong's authority model. |

Recorded in `agent.md` Decision Log in the same PR A commit as this file.

## 4. Layering (agent.md §17 is law)

```
App  →  find bar UI, menu items, focus arbitration with ⇧⌘F
  EditorKit  →  search controller (debounce, off-main Task, cancel, revision fence),
                navigation command emission, optional highlight-all attributes
    MarkdownCore  →  TextSearchEngine + pure find-session model (ordinal, wrap, anchors)
```

- MarkdownCore imports no AppKit/SwiftUI.
- EditorKit must not import WorkspaceKit or App.
- App composes; it does not reimplement matching or navigation.
- No new Swift or npm dependencies. Edit `project.yml` only (never hand-edit
  `.xcodeproj`); run `make generate` after.

## 5. Product contract (v1)

### 5.1 In scope

| Command / control | Behavior |
|---|---|
| `⌘F` | **Toggle** the find bar for the focused editor in the key window: closed → open (and focus the owned query field); open → close (and return focus to the editor). No-op when focus is not an editor that can find (sidebar, preview, no document). |
| `⌘G` | Next match from current ordinal (or from caret anchor when no current match). Wraps last → first within the retained (possibly truncated) match list. |
| `⇧⌘G` | Previous match. Wraps first → last within the retained list. |
| `⌘E` | Use non-empty selection as the find pattern when it is a valid literal (≤ 256 UTF-16, no newlines); otherwise no-op or surface validation without mutating the document. |
| Escape | Close find bar; return focus to the editor. Does not clear document selection unless product copy later says otherwise — default: leave the last navigated selection. |
| Case toggle | UI default mirrors workspace search: smart case; Aa forces sensitive; explicit insensitive remains model-capable even if the first chrome is a single toggle over smart. |
| Whole-word | Independent Unicode whole-word flag (same word characters as workspace search). |
| Match counter | Exact set: `current / total` when `total > 0`. Empty query and zero-match states are distinct. **Truncated set** (limit hit): present distinctly from an exact total — e.g. `current / 10000+` plus a non-color-only truncated indicator — so the UI never implies the document has exactly `limit` matches when more exist. |

#### Match limit (fixed for v1; not implementer discretion)

`TextSearchEngine.matches` requires a `limit:`. v1 always passes:

| Constant | Value | Rationale |
|---|---|---|
| `EditorFindLimits.maximumMatchesPerQuery` | **10_000** | Same ceiling as workspace search’s `WorkspaceSearchLimits.defaultMaximumMatchesPerQuery` (10_000). Keeps one document’s retained match list bounded for ordinal navigation, highlight-all, and counter presentation. WS4B (`docs/perf-log.md`) already budgets production-shaped matching at the 512 KiB admission cap under both case backends and dense whole-word rejection; in-document find is one synchronous call over at most the open buffer (including `Fixtures/large-1mb.md`), so the same order of match work must stay off the main actor (§12 typing &lt; 16 ms). Searching a common letter in a megabyte file is an ordinary case, not a pathological edge — the limit is a product bound, not a rare overflow. |

Session semantics when the engine returns a full `limit` hits:

- Treat the result as **truncated** (`isTruncated == true`) unless a follow-up probe
  (e.g. `limit + 1` or an explicit “at least one more” check) proves no further match
  exists. The implementer must pick one deterministic probe strategy and test it; the
  product rule is that a capped list is never presented as an exact total.
- `total` in the counter is the retained count (≤ 10_000). Truncation is a separate
  flag/UI state, not a silent lie about completeness.
- Next/previous/wrap operate only on the retained list (not on unmaterialized later hits).
- Revising the number requires measured evidence (Debug/Release, recorded in
  `docs/perf-log.md`) — the same discipline as WS4B. Do not widen the limit to rescue a
  failing run.

### 5.2 Deferred (each needs its own gate later)

- **Replace** — requires WS3B writer activation; must not use `NSTextFinder` mutation.
- **Regex** — requires a cancel-safe engine and a Decision Log entry
  (`docs/workspace-search-plan.md` §2.2).
- **Find scoped to a selection.**
- **Find inside the preview pane.**

### 5.3 Hard constraints

1. **Off the main actor.** `TextSearchEngine` is synchronous. WS4B measured a 512 KiB
   file at &lt; 150 ms Debug; `Fixtures/large-1mb.md` is 1 MiB. Per-keystroke main-actor
   matching breaks §12's &lt; 16 ms typing budget. Debounce, run off-main, make it
   cancellable, and fence results by document revision so a stale result cannot move
   the caret.
2. **Find never mutates source text.** Selection and reveal only.
3. **Highlight-all (if implemented) must survive highlight re-application.**
   `MarkdownTextView+HighlightApply.swift` collects and restores
   `WYSIWYGImagePresentationMarker` across `setAttributes`. A find-match attribute
   without the same treatment is silently wiped on every visible-range recompute.
   Prove with a test that applies highlighting between search and assertion (F8).
4. **Focus arbitration must not fight ⇧⌘F.** Workspace-search focus token machinery
   (`AppState+WorkspaceSearchUI` / `WorkspaceSearchUIState`) is authoritative for its
   own field; find-bar focus is a separate intent.
5. **Menu commands route through the responder chain** like Format
   (`EditorCommandDispatcher.perform` → `NSApp.sendAction`), so find applies to the
   focused editor in the key window and no-ops in sidebar/preview.
6. **Built-in finder disable is conditional and co-ships with replacement UI.**
   - If §2 outcome **(a)** holds: disable STTextView’s `NSTextFinder` bar in **PR C**
     (the same PR that ships the Plainsong find bar and menu items), never earlier.
   - If outcome **(b)** holds: disable is a no-op; do not claim a replacement.
   - **Invariant:** no commit on `main` may leave `⌘F` with no working behavior.
     PR B may take exclusive *controller* ownership for navigation/match work without
     removing any existing user-visible entry point.

### 5.4 UI patterns to reuse (WS3C)

- Owned AppKit `NSTextField` for the find query (SwiftUI `FocusState` was rejected in
  WS3C PR A for the search field).
- Pure selection / ordinal reducer for next/previous (testable without AppKit).
- Stable accessibility identifiers under a `plainsong.editorFind.*` namespace.

## 6. Architecture sketch (non-binding names; capabilities are binding)

### 6.1 MarkdownCore — find session (PR B)

Pure value types over `TextSearchEngine` results, for example:

- query + options + fixed `limit` (10_000) → matches + `isTruncated`
- session state: matches, current ordinal (1-based UI), last caret anchor UTF-16,
  truncation flag
- pure functions: `next(from:)`, `previous(from:)`, `ordinal(nearestTo:preferring:)`,
  wrap-around at both ends, empty / oversized / newline / zero-match / truncated
  handling

No I/O, no actors, no AppKit.

### 6.2 EditorKit — search controller (PR B)

- Observe document text / revision (existing session publication, not
  `objectWillChange` on every keystroke).
- Debounce query changes; cancel in-flight match Tasks; run
  `TextSearchEngine.matches` off the main actor with the fixed limit.
- Fence completions by `(documentIdentity, sourceRevision, queryGeneration)`.
- Emit `EditorNavigationCommand.navigate` with a new monotonic ID for every
  next/previous/activate — including re-activating the same match — so the WS3A
  state machine never treats a legitimate re-selection as a stale ID.
- Rebind or clear the session on document-lifecycle transitions defined in F4/F4b
  (identity change is not only a stale-request reject; it is a defined session action).
- Optional highlight-all attribute application with the same preservation contract as
  image markers (F8 may land in PR D).

### 6.3 App — find bar + menus (PR C)

- Find bar chrome above or below the focused editor pane (implementation detail;
  prefer not fighting the STTextView gutter / scroll geometry).
- Menu items: Find, Find Next, Find Previous, Use Selection for Find — responder-chain
  routed.
- Focus intents independent of `WorkspaceSearchUIState` tokens.
- If §2 outcome (a): disable built-in `NSTextFinder` **here**, with the replacement UI.
- Must not be authored until F0 has recorded the delivery mechanism (§8 F0).

### 6.4 Performance probe (PR D)

Add a `PerformanceTests` probe over `Fixtures/large-1mb.md`:

1. Measure first (Debug and Release), at least three runs each.
2. Record numbers in `docs/perf-log.md`.
3. Freeze the budget from measured Debug medians (same discipline as WS4B).
4. Do not invent a budget; do not widen a budget to rescue a failing run.
5. Wall-clock budgets are hard locally and informational on hosted CI under R15.
6. Include a live-query / find-open typing-latency sample that closes F2’s product
   latency bullet (agent.md §17.8) — structural off-main tests in PR B are not enough.

## 7. PR split

One review-sized PR each. Branch naming: `phase3-editor-find-<slug>`. PRs against
`main`. Maintainer squash-merges. Never push to `main`, never merge your own PR.

| PR | Scope | Gates closed |
|---|---|---|
| **A** (this PR) | Spec only: this file + Decision Log engine entry. No behavior change. | none (documents F0–F9 open) |
| **B** | **F0 blocking spike first** (I0-shaped: minimal menu item if needed, owner physical `⌘F` under ABC + Zhuyin, record menu route vs Carbon fallback — before or as the first commit). Then MarkdownCore find-session model + EditorKit search controller (off-main, debounced, cancellable, revision-fenced, fixed 10_000 limit + truncation) navigating through existing navigation API. **No App find-bar UI.** Must **not** remove any existing `⌘F` entry point (invariant §5.3 #6). | F0 (owner evidence), F1–F5 (named tests). F2’s product latency bullet remains open until PR D measures it. |
| **C** | App find bar UI + menu items + focus arbitration with ⇧⌘F. F6 IME in find field; F7 focus arbitration. If §2 (a): disable built-in finder **in this PR** with the replacement. **Do not start PR C until F0 has fixed the delivery mechanism.** | F6, F7 |
| **D** | XCUITest (F9, including truncated counter state), performance probe with frozen budgets (closes F2 latency), highlight-all + F8. | F2 (latency bullet), F8, F9 + perf |

Before declaring any PR done: `make format && make lint && make test && make build`,
and `git diff --check`. PR body must list which F-gates it closes and which remain
open. Check a gate box only with named-test evidence.

## 8. Gates

Checkboxes start unchecked. Evidence lines are filled when the gate closes.

### F0 — ⌘F key delivery (blocking mechanism spike; owner physical keyboard)

Shape matches image-thumbnail **I0**: a minimal spike that decides the mechanism before
production UI work. This is **not** a late verification detail of PR D.

- [ ] **PR B precondition:** run the §2 runtime Edit-menu / `⌘F` check and record
  outcome **(a)** or **(b)**.
- [ ] Ordinary menu-item route delivers Find under **ABC** and **Zhuyin** on a
  **physical** keyboard. Prefer the menu-item / standard key-equivalent path first.
- [ ] Do **not** preemptively add a second Carbon hot key registration. Fall back to the
  `PlainsongMenuKeyBinding` / app-active Carbon pattern **only** if physical delivery
  actually fails, and record the evidence either way (Decision Log 2026-07-22 precedent
  for ⇧⌘F).
- [ ] Synthetic `NSEvent`s and XCUITest input are **not** evidence for this gate.
- [ ] Spike stays minimal (e.g. one temporary menu item if none exists yet); no full find
  bar. PR C must not be authored until the mechanism is known and recorded here.
- Evidence: _open — owner physical run as first work of PR B (before or as first commit);
  not PR D_

### F1 — Pure find-session model

- [ ] Ordinal is well-defined for zero, one, and many matches.
- [ ] Next / previous from an arbitrary caret anchor select the correct match.
- [ ] Wrap-around at both ends (last→first, first→last) within the retained list.
- [ ] Empty pattern, oversized pattern (&gt; 256 UTF-16), and newline-containing
  patterns yield no matches (engine rules) and a defined session empty state.
- [ ] Single-match next/previous is stable (stays on the only match; still emits a fresh
  navigation ID at the controller layer — covered under F3).
- [ ] Fixed limit **10_000** is applied; session can express **truncated** vs exact;
  wrap/next/previous never assume unmaterialized hits exist beyond the retained list.
- Evidence: _open — PR B MarkdownCore tests_

### F2 — Off-main, debounced, cancellable (+ measured latency in PR D)

- [ ] Match work runs off the main actor; query changes cancel in-flight work.
  Evidence: _open — PR B EditorKit tests_
- [ ] Results are fenced by document revision / query generation; stale completions do
  not apply. Evidence: _open — PR B EditorKit tests_
- [ ] Typing latency on `Fixtures/large-1mb.md` is unchanged with the find bar open and
  a live query (no main-actor full-document match on the keystroke path). §12 &lt; 16 ms
  typing budget remains the hard product gate (agent.md §17.8: state how typing latency
  was verified when the edit path is touched). **A written assertion or structural
  off-main test alone does not close this bullet** — it closes only with measured
  evidence from the PR D performance probe (`docs/perf-log.md`).
  Evidence: _open — PR D perf probe + recorded numbers_

### F3 — Exact UTF-16 navigation through EditorNavigationRequest

- [ ] Activating a match selects the exact half-open UTF-16 range and reveals it.
- [ ] Repeated activation of the **same** match works (monotonic navigation IDs).
- [ ] Stale requests (older ID, wrong document identity, invalid range, marked text /
  not-installed) are rejected without clamping. (Rejection is a defense; defined
  lifecycle rebinding is F4/F4b, not “ignore and hope.”)
- Evidence: _open — PR B EditorKit navigation tests_

### F4 — Edit invalidation

- [ ] Editing the document while find is open invalidates the match set and recomputes
  (debounced) against the new revision.
- [ ] A stale match list cannot jump the caret after an edit.
- Evidence: _open — PR B_

### F4b — Document lifecycle (defined behavior, not only stale rejection)

F3’s wrong-`documentIdentity` reject is necessary but not sufficient. Preview once
stranded on a previous document when ordering was keyed only on a per-document version
(Decision Log 2026-06-14 `renderID`). Find session state must follow the focused
document explicitly. **Defined v1 behaviors** (bar open unless noted):

| Transition | Intended behavior |
|---|---|
| Sidebar switches to another Markdown/MDX file | Bar **stays open**. Cancel in-flight work for the old identity. Clear matches/ordinal/highlight-all for the old document. Rebind the session to the new `EditorDocumentIdentity` + revision and **re-run the same query/options** against the new text (or show empty/no-document state if the new selection is not a searchable document). Never leave the counter or selection pointing at the previous file’s ranges. |
| `⇧⌘F` result activates a different document | Same as sidebar switch: stay open, rebind, re-run. Focus arbitration with workspace search remains F7. |
| External disk change → Reload | Same document identity, new bytes/revision: invalidate and recompute (same as F4 edit path) after Reload has converged; do not navigate using pre-Reload ranges. |
| External disk change → Keep Mine | Local source remains authority: recompute only if revision/text actually changed; do not adopt disk ranges. |
| Warm session LRU eviction / retirement of a **non-focused** session | No find-session effect while that session is not the focused editor document. |
| Focused session retired / closed / no open document | **Close** the find bar, cancel work, clear session. No orphan bar over an empty editor. |
| Workspace close / switch | Close the find bar and clear session (query may be discarded with the window’s document context; no cross-workspace stranding). |

- [ ] Named tests cover at least: file switch rebind+rerun, Reload recompute without
  stale jump, and close-on-no-document. Rejection of stale navigation IDs alone does not
  close this gate.
- Evidence: _open — PR B (controller) + PR C where UI visibility is required_

### F5 — Reveal without source mutation (WYSIWYG + source+preview)

- [ ] A match inside a folded WYSIWYG span reveals that span via the existing
  navigation / reveal path.
- [ ] Source text is byte-identical before and after find navigation.
- [ ] Covered with Experimental WYSIWYG both **off** and **on**.
- [ ] Covered in **source+preview** layout mode: find navigation moves the editor
  selection, which must keep preview scroll sync green via the existing scroll proxy
  (Decision Log 2026-06-25). Source-only remains green as the non-preview control.
  (`docs/workspace-search-plan.md` §7 requires preview / source-only / WYSIWYG stay
  green for search-related navigation.)
- Evidence: _open — PR B_

### F6 — IME in the find field

- [ ] Composing in the find field must not commit into the document.
- [ ] Escape and Return during marked text belong to the input context (same discipline
  as `MarkdownSTTextView`'s reservation of space / Return / keypad Enter while marked
  text exists).
- Evidence: _open — PR C_

### F7 — Focus arbitration with ⇧⌘F

- [ ] Sequence `⌘F` → `⇧⌘F` → Escape leaves focus somewhere sane every time (find field,
  workspace-search field, or editor — never a dead control).
- [ ] Neither feature's focus receipt is consumed by the other.
- [ ] Find focus tokens are independent of `WorkspaceSearchUIState` request/applied IDs.
- Evidence: _open — PR C hosted tests_

### F8 — Highlight-all survives highlight re-application

- [ ] If highlight-all is implemented, find-match attributes survive
  `applyHighlightedText` / visible-range recompute the same way image presentation
  markers do.
- [ ] Named test applies highlighting **between** search attribute application and the
  assertion (proves preservation, not just initial paint).
- [ ] If highlight-all is deferred out of v1, this gate stays open and PR D must say so
  explicitly rather than checking the box.
- Evidence: _open — PR D (or explicit deferral)_

### F9 — Accessibility + XCUITest

- [ ] Stable accessibility identifiers under `plainsong.editorFind.*` for the bar,
  query field, case/whole-word controls, match counter, next/previous controls, and
  **truncated-state** indicator (when the 10_000 limit is hit).
- [ ] Match counter’s truncated presentation is distinct from an exact total (not
  color alone).
- [ ] `PlainsongUITests` coverage following the WS4A fixture pattern: app-container
  fixture, predicate waits, no `NSOpenPanel` automation, synthetic events only (not F0
  evidence).
- Evidence: _open — PR D_

## 9. Performance gate (PR D)

| Step | Rule |
|---|---|
| Measure first | Probe real find over `Fixtures/large-1mb.md` through the production controller path (or the nearest production-shaped API), including a find-open live-query typing sample for F2. |
| Sample size | ≥ 3 Debug + ≥ 3 Release runs, recorded in `docs/perf-log.md` with commit SHA and reproduction commands. |
| Freeze | Budget from Debug medians (because `make test` is Debug), same as WS4B. |
| Discipline | No invented budgets; no widening to rescue a run — fix harness or code. |
| CI | Wall-clock hard locally, informational on hosted CI under R15; deterministic correctness assertions hard everywhere. |

## 10. Non-goals for this gate set

- Workspace-wide find (already ⇧⌘F).
- Replace, regex, selection-scoped find, preview-pane find (deferred §5.2).
- Changing `TextSearchEngine` semantics.
- Claiming overall Workspace Search DoD complete.

## 11. Sign-off

| Role | Responsibility |
|---|---|
| Implementer | Named tests for F1–F9 as listed; no checkbox without evidence. |
| Owner | **F0 physical-keyboard spike at the start of PR B** under ABC + Zhuyin (menu route first; Carbon only if that fails); merge authority. F0 is not deferred to PR D. |
| Maintainer | Squash-merge after review + green CI; never author self-merge. |
