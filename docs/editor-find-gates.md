# In-Document Find (⌘F) — Gate Specification

> **Status: PR A (#95), PR B (#96), and PR C (#97) are merged.** §2 is resolved
> **(b)**; F0 closed with owner physical ABC+Zhuyin in PR B. F1–F4 controller half +
> F5 WYSIWYG/source identity closed in PR B, and PR C supplies the production App UI and
> navigation-ID wiring. **F4b hosted UI, F5 source+preview, F6, and most of F7 remain
> open** until their named hosted/owner evidence lands. A separate F2 measurement tip
> records query-completion and hosted native-edit admission/root-update **proxies only**;
> full physical-input → child-layout → compositor keystroke-to-screen latency remains
> open. This dedicated `phase3-editor-find-f9-ui-acceptance` follow-up implements F9 and the
> repeated-⌘F sub-gate of F7; §8 records the still-pending successful exact-tree strengthened
> 3× execution. F8 remains a separate pending follow-up; no
> F2/F8/F9 combined-tip evidence is claimed. Precedent: PR #45, link-folding,
> image-thumbnail gate docs.
> Check a gate box only with named-test or owner-recorded evidence in the same commit.
>
> The 2026-07-27 review restack moved the navigation transport (`shouldFocusEditor`) into
> PR B so #96 compiles standalone, and PR C added production-path lifecycle coverage plus a
> shared focus receipt, find-bar chrome eligibility, and workspace-search / close-bar
> fencing. A second review round then replaced the AppKit find-bar ancestor walk with
> SwiftUI-reported chrome focus (macOS flattens the bar and the editor into one hosting view,
> so that walk could not fire in production), removed Escape as a Done key equivalent so it
> can no longer bypass the query field's IME reservation, made close preserve the resolved
> ordinal, shared the select-all receipt, and gave the applied-selection probe
> document/revision provenance. **No gate box was checked by either round**: hosted
> first-responder and UI-visibility evidence is still what F4b UI, F5 source+preview, F6, and
> F7 are waiting on.
>
> A third round then tagged chrome-focus reports with the reporting window (an App-global
> value let a background window's focus grant eligibility in the key one), restored Escape as
> a close path from the editor and from bar chrome — which removing the Done key equivalent
> had broken — and gave the selection cache the same revision provenance the live probe
> already had. A fourth round scoped report *clearing* to the owning window (tagging alone
> still let a background window wipe the key window's live report), moved the window lookup
> onto a deferred `EditorFindBarWindowBridge` instead of writing `@State` from
> `updateNSView`, and restacked the branch onto `main` after #96 merged. A fifth round
> replaced the single tagged report with **one report per window**, because a non-`nil` report
> from any window still replaced the only slot — so returning to a window whose bar still held
> focus republished nothing and left its ⌘G / ⌘E dead — and gave the bridge generation
> fencing, because it compared against its own turn-stale published value.
>
> Known un-automated: **F6** — removing the Done key equivalent is verifiable by inspection
> but not by an in-process test, because reproducing the bypass needs a real IME. It stays
> covered by the owner IME smoke item that already blocks F6.

Created 2026-07-27 as Phase 3 Goal 14 after WS3C/WS4A landed workspace search (⇧⌘F).
See `agent.md` §6.4 (shortcuts), §12 (performance), §17 (layering / collaboration),
`docs/workspace-search-plan.md` §4.1 (MarkdownCore search model) and §4.4 (App/editor
navigation), and the Decision Log entry that freezes the engine choice.

## 1. Outcome

Ship Typora-class in-document find for the focused editor pane:

- `⌘F` shows or re-focuses a find bar owned by the focused editor in the key window
  (never closes the bar — see §5.1).
- `⌘G` / `⇧⌘G` move to next / previous match with wrap-around at both ends
  (Typora behavior; agent.md §17.12).
- `⌘E` uses the current selection as the find pattern (when non-empty and valid).
- Escape closes the find bar and returns focus to the editor.
- Match counter shows current ordinal / total, with a distinct truncated state when
  the retained match ceiling is hit (§5.1).
- Case-sensitivity and whole-word toggles match the workspace-search model
  (smart/sensitive/insensitive + Unicode whole-word).
- Navigation selects and reveals exact UTF-16 ranges through the existing
  `EditorNavigationRequest` / `EditorNavigationCommand` path — never a second
  selection/scroll channel.
- Find **never mutates source text**. Selection and reveal only.

Workspace search (`⇧⌘F`) remains independent. Neither feature's focus receipt may
consume the other's token.

## 2. Historical baseline: what ⌘F did before merged PR #97

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

**RESOLVED 2026-07-27 (owner run, Debug app at `main` `dfba18a`): outcome (b).**

| Step | Observation |
|---|---|
| Edit menu inspection | **No Find submenu and no Find… item.** The menu is fully constructed and merely validated — Undo, Redo, Cut, Copy and Delete are all present but disabled — so an item synthesized by SwiftUI would have appeared disabled rather than absent. It is absent. |
| Physical `⌘F`, ABC and Zhuyin | **System beep in both**, no find bar. |

Consequences, applied throughout this document:

- There is **nothing to replace**. “Disable the built-in finder” is a no-op, and no PR
  body may claim a replacement (§5.3 #6, §6.3, §7 PR B/PR C).
- STTextView's `NSTextFinder` stack exists but is **unreachable**: nothing sends
  `performTextFinderAction:` without a menu item, and NSTextView-family views carry no
  built-in `⌘F` key binding of their own. `⌘G` and `⌘E` are likewise inert today.
- The invariant “no commit on `main` may leave `⌘F` with no working behavior” is
  **trivially satisfied** — `⌘F` has no behavior to lose. It stays in the document
  because it still governs the window between PR C's UI landing and any later change.

**What the beep proves, and what it does not.** The beep means the event reached the app,
completed key-equivalent resolution, and was claimed by no responder. That is the opposite
of the ⇧⌘F failure mode, where the physical event was consumed *before* AppKit and the app
observed nothing at all (Decision Log 2026-07-22) — so **⌘F is not intercepted upstream and
a Carbon fallback is not expected to be needed.** It does **not** prove that SwiftUI will
dispatch a newly added menu item's key equivalent: `App/PlainsongCommands.swift` records
that SwiftUI swallowed ⇧⌘P/⇧⌘F key equivalents without firing their actions while two
top-level menus shared a title, even though mouse clicks worked. **F0 therefore stayed open**
until the minimal spike added a Find menu item and an owner physical `⌘F` fired it.

F0 was a **blocking spike** (I0-shaped; see §7 / §8 F0): it fixed the delivery
mechanism before merged PR #97 shipped the bar. Synthetic `NSEvent`s and XCUITest
input are **not** F0 evidence (Decision Log 2026-07-22).

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
| `⌘F` | **Show / re-focus** the find bar for the focused editor in the key window. **Closed →** open the bar, focus the owned query field, and select all retained query text (if any) so typing replaces it. **Already open →** keep the bar open, focus the query field, and select all existing query text — **never closes**. Escape (and F4b lifecycle closes) remain the only close paths. No-op when focus is not an editor that can find (sidebar, preview, no document). **Owner decision (not re-litigated):** agent.md §17.12 orders UX tiebreaks Typora first, macOS HIG second; both agree — macOS models find as distinct show/hide actions (`NSTextFinder.Action.showFindInterface` / `hideFindInterface`), with Edit ▸ Find ▸ Find… bound to *show*, not hide-on-repeat. The practical driver is the highest-frequency flow: search A, review matches, then search B is one keypress under re-focus and two if a second `⌘F` closed the bar. |
| `⌘G` | Next match from current ordinal (or from caret anchor when no current match). Wraps last → first within the retained (possibly truncated) match list. |
| `⇧⌘G` | Previous match. Wraps first → last within the retained list. |
| `⌘E` | Use non-empty selection as the find pattern when it is a valid literal (≤ 256 UTF-16, no newlines); otherwise no-op without mutating the document. **PR C decision (macOS convention):** `⌘E` does **not** show or focus the find bar — it only sets the pattern so a following `⌘G` can jump with the bar still hidden. Never closes an open bar. Format ▸ Inline Code keeps the menu item but no longer claims `⌘E` (Decision Log). Evidence: `EditorFindUITests.testUseSelectionForFindSetsPatternWithoutShowingBar`. |
| Escape | Close find bar; return focus to the editor. Does not clear document selection unless product copy later says otherwise — default: leave the last navigated selection. |
| Case toggle | UI default mirrors workspace search: smart case; Aa forces sensitive; explicit insensitive remains model-capable even if the first chrome is a single toggle over smart. |
| Whole-word | Independent Unicode whole-word flag (same word characters as workspace search). |
| Match counter | Exact set: `current / total` when `total > 0` and `isTruncated == false`. Empty query and zero-match states are distinct. **Truncated set** (`isTruncated == true`): present distinctly from an exact total — e.g. `current / 10000+` plus a non-color-only truncated indicator — so the UI never implies the document has exactly `retainedMatchCeiling` matches when more exist. |

#### When match completion emits navigation (fixed product rule)

The controller schedules match work for several reasons. **Only some of them move the
selection.** Explicit next/previous/activate always navigate (they do not go through the
schedule path). Scheduled completions:

| Reason | Recompute session / counter | Emit `EditorNavigationCommand` |
|---|---|---|
| **Query change** (`setQuery`) | Yes | **Yes** — navigate to the match resolved from the caret anchor |
| **Document edit** (`documentTextDidChange`) | Yes | **No** — leave the user's selection alone. Preserve `currentOrdinal` when that ordinal still exists in the new match list; otherwise resolve from the caret anchor (session init fallback). |
| **Document rebind / file switch** (`rebindDocument`) | Yes (after clearing the old identity's session) | **No** — update the counter for the new document; the user moves with `⌘G` / next. Never auto-jump into the newly focused file. |

This is implemented by threading `EditorFindScheduleReason` through `scheduleMatch` into
apply; the reason must not be discarded. Tests: edit without navigation emission; rebind
without navigation emission.

#### Match limit (fixed for v1; not implementer discretion)

`TextSearchEngine.matches` requires a `limit:`. v1 uses a **retained ceiling** plus a
one-shot overflow probe in a single engine call — no implementer choice of strategy:

| Constant | Value | Role |
|---|---|---|
| `EditorFindLimits.retainedMatchCeiling` | **10_000** | Maximum matches the session keeps; maximum value the counter’s `total` can show for an exact set. |
| Engine `limit:` argument | **`retainedMatchCeiling + 1` (10_001)** | Always. Detects truncation in one call. |

| Rationale for the ceiling | |
|---|---|
| Parity | Same number as workspace search’s `WorkspaceSearchLimits.defaultMaximumMatchesPerQuery` (10_000 at `WorkspaceSearchModels.swift`). |
| Product bound | Keeps one document’s retained match list bounded for ordinal navigation, highlight-all, and counter presentation. Searching a common letter in a megabyte file is an ordinary case, not a pathological edge. |
| Performance | WS4B (`docs/perf-log.md`) already budgets production-shaped matching at the 512 KiB admission cap under both case backends and dense whole-word rejection; in-document find is one synchronous call over at most the open buffer (including `Fixtures/large-1mb.md`), so that work must stay off the main actor (§12 typing &lt; 16 ms). |

**Session algorithm (fixed):**

1. Call `TextSearchEngine.matches(..., limit: retainedMatchCeiling + 1)`.
2. If the engine returns **`retainedMatchCeiling + 1`** results: drop the extra match,
   retain the first **10_000**, set `isTruncated = true`. Counter `total` is 10_000 and
   the truncated UI state is shown (e.g. `current / 10000+`).
3. If the engine returns **`≤ retainedMatchCeiling`** results: retain all of them,
   set `isTruncated = false`. Counter `total` is exact.
4. Next / previous / wrap operate **only** on the retained list (never on unmaterialized
   later hits).

Revising `retainedMatchCeiling` requires measured evidence (Debug/Release, recorded in
`docs/perf-log.md`) — the same discipline as WS4B. Do not widen the ceiling to rescue a
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
6. **Built-in finder disable — resolved to no-op by §2 outcome (b).**
   - §2 is **resolved (b)** (2026-07-27 owner run): no reachable built-in path exists, so
     there is nothing to disable and no PR may claim a replacement.
   - The conditional (a) branch is retained in §2 for provenance only. If a future change
     ever makes STTextView's finder reachable, disabling it co-ships with the Plainsong
     bar in the same PR — never earlier.
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

- query + options + engine results from `limit: retainedMatchCeiling + 1` →
  retained matches (≤ 10_000) + `isTruncated` (true iff the engine returned 10_001)
- session state: retained matches, current ordinal (1-based UI), last caret anchor
  UTF-16, truncation flag
- pure functions: `next(from:)`, `previous(from:)`, `ordinal(nearestTo:preferring:)`,
  wrap-around at both ends, empty / oversized / newline / zero-match / truncated
  handling

No I/O, no actors, no AppKit.

### 6.2 EditorKit — search controller (PR B)

- Observe document text / revision (existing session publication, not
  `objectWillChange` on every keystroke).
- Debounce query changes; run
  `TextSearchEngine.matches(..., limit: retainedMatchCeiling + 1)` off the main actor
  (real `!Thread.isMainThread` flag); drop overflow hits per §5.1.
- Fence completions by `(documentIdentity, sourceRevision, queryGeneration)`; supersession
  drops stale results at apply time (engine work is not interruptible).
- Emit navigation on **query** completion and on explicit next/previous/activate only —
  **not** on edit or rebind (§5.1 table).
- Rebind or clear the session on document-lifecycle transitions defined in F4/F4b
  without auto-jump. PR B landed the controller half; merged PR #97 owns the App UI,
  while hosted UI-visibility evidence remains separately open.
- Optional highlight-all attribute application with the same preservation contract as
  image markers (separate pending F8 follow-up).

### 6.3 App — find bar + menus (merged PR #97)

- Find bar chrome above or below the focused editor pane (implementation detail;
  prefer not fighting the STTextView gutter / scroll geometry).
- Menu items: Find, Find Next, Find Previous, Use Selection for Find — responder-chain
  routed.
- Focus intents independent of `WorkspaceSearchUIState` tokens.
- No built-in `NSTextFinder` disabling: §2 resolved **(b)**, nothing is reachable.
- Must not be authored until F0 has recorded the delivery mechanism (§8 F0).

### 6.4 Performance probes (separate F2 follow-up)

Add a `PerformanceTests` probe over `Fixtures/large-1mb.md`:

1. Measure first (Debug and Release), at least three runs each.
2. Record numbers in `docs/perf-log.md`.
3. Freeze the budget from measured Debug medians (same discipline as WS4B).
4. Do not invent a budget; do not widen a budget to rescue a failing run.
5. Wall-clock budgets are hard locally and informational on hosted CI under R15.
6. Include a production-hosted live-query / find-open typing-latency sample. Close only
   the named interval it measures; a native `insertText` admission or root-update receipt
   does not prove physical delivery, child-layout completion, compositor presentation, or
   the full agent.md §12 keystroke-to-screen criterion.

## 7. PR split

One review-sized PR each. Branch naming: `phase3-editor-find-<slug>`. PRs against
`main`. Maintainer squash-merges. Never push to `main`, never merge your own PR.

| PR | Scope | Gates closed |
|---|---|---|
| **A** (merged as #95) | Spec only: this file + Decision Log engine entry. No behavior change. | none (documents F0–F9 and F4b open) |
| **B** (merged as #96) | **F0 blocking spike + owner physical sign-off.** MarkdownCore find-session model + EditorKit search controller (debounced off-main match; fence drops stale results including after `cancelInFlightWork`; engine `limit: retainedMatchCeiling + 1`; session invalidated at schedule so next/previous cannot use superseded ranges; first next/previous after edit/rebind activates current ordinal; optional `navigationIDProvider` for shared App high-water mark). Lands the **controller half of F4b** without closing F4b. **No App find-bar UI.** | **Closes:** F0; F1; F2 structural; F3 exact-range (+ provider contract for shared ID domain); F4; F5 WYSIWYG off/on + source identity. **Does not close:** full F2 keystroke-to-screen latency; F4b hosted UI; F5 source+preview; F6–F9. |
| **C** (merged as #97) | App find bar UI + menu items + responder-chain delivery + focus arbitration with ⇧⌘F. Installs `navigationIDProvider`. Lifecycle hooks for Reload/rename/Save Copy/close. No built-in-finder disabling (§2 (b)). Decides open `⌘E` (pattern-only, no auto-nav). | Shared navigation ID domain in production; **does not close** F4b hosted UI / F5 live preview / F6 / F7 until named hosted evidence |
| **F2 proxy follow-up** (separate tip) | Measures exact 1 MiB query completion plus production-hosted native `insertText` admission and root App/SwiftUI update receipt. | Closes only the named proxy budgets. Full physical-input, child-layout, compositor, and cold O(n) scroll-index work remain outside the proof. |
| **F9 follow-up** (`phase3-editor-find-f9-ui-acceptance`) | App-container Debug fixture, launched-app stable AX surfaces, first/repeated synthetic `⌘F`, exact/truncated state, observable chrome actions, lease-protected app-owned cleanup, and ownership-safe runner restoration. | Implements F9 and the repeated-⌘F sub-gate of F7; exact-tip closure remains pending a successful strengthened 3× execution. Does not claim physical-keyboard/IME evidence. |
| **F8 follow-up** (separate, pending) | Highlight-all implementation, if retained, plus preservation across highlight re-application. | F8 remains open; no highlight-all work or evidence is part of F9. |

Before declaring any PR done: `make format && make lint && make test && make build`,
and `git diff --check`. PR body must list which F-gates it closes and which remain
open. Check a gate box only with named-test evidence.

## 8. Gates

Checkboxes start unchecked. Evidence lines are filled when the gate closes.

### F0 — ⌘F key delivery (blocking mechanism spike; owner physical keyboard)

Shape matches image-thumbnail **I0**: a minimal spike that decides the mechanism before
production UI work. This is **not** a late verification detail of a performance follow-up.

- [x] **PR B precondition:** run the §2 runtime Edit-menu / `⌘F` check and record
  outcome **(a)** or **(b)**. — **Done 2026-07-27 (owner, Debug app at `main` `dfba18a`):
  outcome (b).** No Find submenu or Find… item in the Edit menu (menu fully constructed;
  Undo/Redo/Cut/Copy/Delete present but disabled). Physical `⌘F` under **ABC** and
  **Zhuyin** both produced a system beep and no find bar. See §2 for the resolution and
  its consequences.
- [x] Ordinary menu-item route delivers Find under **ABC** and **Zhuyin** on a
  **physical** keyboard. Prefer the menu-item / standard key-equivalent path first.
  **Spike (PR B) + owner physical sign-off 2026-07-27:** menu item
  `CommandGroup(after: .pasteboard)` **Find…** (`⌘F`) → `performShowFind` →
  `sendAction(plainsongShowFind:)` → focused editor. Owner confirmed Console
  `app.plainsong.editor` / `F0 spike` logs under **ABC** and **Zhuyin**
  (`menu/key equivalent invoked`, `delivered=true`, `plainsongShowFind fired`).
  No Carbon hot key. Unit path remains
  `EditorFindSpikeTests.testShowFindSelectorRecordsFireOnFocusedEditor` (not F0
  evidence).
- [x] Do **not** preemptively add a second Carbon hot key registration. — No Carbon
  registration added; spike uses menu + sendAction only. Fall back only if physical
  delivery fails (Decision Log 2026-07-22 precedent for ⇧⌘F).
- [x] Synthetic `NSEvent`s and XCUITest input are **not** evidence for this gate. —
  Recorded: unit tests cover selector delivery only; physical remains required.
- [x] Spike stays minimal (one Find… menu item; fire counter only; no find bar). —
  `App/PlainsongCommands.swift` + `EditorFindSpike.swift`; merged PR #97 owns the bar.
- Evidence: **closed 2026-07-27.** §2 outcome (b); menu route spike in PR B; owner
  physical `⌘F` under **ABC** and **Zhuyin** confirmed via Console `F0 spike` logs
  (`delivered=true` + `fired`). Mechanism = ordinary menu item + `sendAction` (no Carbon).

### F1 — Pure find-session model

- [x] Ordinal is well-defined for zero, one, and many matches.
  Evidence: `EditorFindSessionTests.testZeroOneAndManyMatchesHaveWellDefinedOrdinals`
- [x] Next / previous from an arbitrary caret anchor select the correct match.
  Evidence: `EditorFindSessionTests.testOrdinalNearestToArbitraryCaretAnchor`
- [x] Wrap-around at both ends (last→first, first→last) within the retained list.
  Evidence: `EditorFindSessionTests.testNextAndPreviousWrapAtBothEnds`
- [x] Empty pattern, oversized pattern (&gt; 256 UTF-16), and newline-containing
  patterns yield no matches (engine rules) and a defined session empty state.
  Evidence: `EditorFindSessionTests.testEmptyOversizedAndNewlinePatternsYieldEmptySession`
- [x] Single-match next/previous is stable (stays on the only match; still emits a fresh
  navigation ID at the controller layer — covered under F3).
  Evidence: `EditorFindSessionTests.testSingleMatchNextPreviousStaysOnOnlyMatch`;
  controller re-activation:
  `EditorFindControllerTests.testActivateEmitsExactUTF16NavigationWithMonotonicIDs`
- [x] Engine is always called with `limit: retainedMatchCeiling + 1` (10_001); session
  retains at most **10_000** matches; `isTruncated` is true iff the engine returned
  10_001 (extra dropped); false when count ≤ 10_000 (exact `total`). Wrap / next /
  previous never assume unmaterialized hits beyond the retained list.
  Evidence: `EditorFindSessionTests.testTruncationAtCeilingAndOverflow`,
  `...testEngineResultsCeilingPlusOneDropsOverflow`
- Evidence: **closed in PR B** — `Packages/MarkdownCore/.../EditorFindSession.swift` +
  `EditorFindSessionTests`

### F2 — Off-main, debounced, result-dropping (+ named latency proxies)

Match admission is debounced. Production match work runs in `Task.detached` and records
whether the worker observed `!Thread.isMainThread` (not a hardcoded flag). Rapid query
replace cancels the **admission** task and advances the generation fence.

**Honest cancellation claim:** `Task.detached` does not inherit cancellation and
`TextSearchEngine.matches` has no cancellation points. A superseded match may still run to
completion; what is guaranteed is that its result is **dropped at apply time** when the
fence no longer matches (and debounce prevents most redundant admissions). Do not claim
interruption of in-flight engine work.

- [x] Match work runs off the main actor (flag from `!Thread.isMainThread` inside the
  worker) with a main-actor **negative control** that reports `false`.
  Evidence: `EditorFindControllerTests.testMatchWorkRunsOffMainAndReportsTrueFlag`,
  `...testMainActorMatchPathReportsOffMainFalse`
- [x] Query changes cancel prior admission and only the latest generation applies.
  Evidence: `EditorFindControllerTests.testRapidQueryReplaceCancelsPriorAdmissionAndAppliesLatest`
  (`cancelledMatchCount >= 1`)
- [x] Results are fenced by document revision / query generation; stale completions
  increment `droppedStaleMatchCount` and do not apply.
  Evidence: `EditorFindControllerTests.testStaleMatchCompletionIsDropped` (deterministic
  hold seam: first generation held, second applied, first released and dropped);
  `EditorFindControllerLifecycleTests.testCancelInFlightWorkAdvancesFenceSoDetachedWorkerCannotApply`
- [x] Scheduling a new match (query / edit / rebind) **immediately** clears `session` and
  `pendingNavigationCommand` so next/previous/activate during debounce cannot emit a
  superseded range under a new revision.
  Evidence: `EditorFindControllerLifecycleTests.testScheduleMatchInvalidatesSessionSoNextDoesNotUseStaleRanges`
- [x] The separate measured source `9de4157f71a1e9fb12cdde696d7e3214b8feff4f`
  records deterministic zero, sparse, and dense-truncated completion through App query
  publication, the production debounce, detached matching/fencing, and App presentation.
  Evidence:
  `EditorFindPerformanceTests.testLargeFixtureFindQueryCompletionForZeroSparseAndDenseCases`.
- [x] That same separate tip records a production-hosted **proxy** beginning at native
  programmatic `insertText` admission and ending at a root App/SwiftUI state-update
  receipt, with the old find session invalidated synchronously and the exact eventual
  dense result recomputed off-main.
  Evidence:
  `EditorFindPerformanceTests.testProductionWorkspaceFindOpenEditAdmissionAndStateReceiptStayWithinMeasuredBudgets`.
  This is consumer-observation evidence for those named intervals, not proof of physical
  input, child-layout completion, compositor presentation, or equality with find-closed.
- [ ] Full agent.md §12 &lt;16 ms **keystroke-to-screen** latency with find open is
  proven end-to-end. The named proxies begin after physical input and stop before child
  layout/compositor completion. Their retained samples also expose a one-off synchronous
  O(n) preview-scroll line-index rebuild outside find matching. Resolve or explicitly
  cover those gaps before checking this box.
- Evidence: **partial on a separate F2 tip only.** The proxy evidence above was not run
  on, combined with, or recharacterized as evidence for this F9 tip.

### F3 — Exact UTF-16 navigation through EditorNavigationRequest

- [x] Activating a match selects the exact half-open UTF-16 range and reveals it.
  Evidence: `EditorFindControllerTests.testActivateEmitsExactUTF16NavigationWithMonotonicIDs`,
  `EditorFindControllerTests.testNavigationAppliesThroughExistingEditorNavigationPath`
- [x] Repeated activation of the **same** match works (monotonic navigation IDs).
  Evidence: `EditorFindControllerTests.testActivateEmitsExactUTF16NavigationWithMonotonicIDs`
- [x] Stale requests (older ID, wrong document identity, invalid range, marked text /
  not-installed) are rejected without clamping. (Rejection is a defense; defined
  lifecycle rebinding is F4/F4b, not “ignore and hope.”)
  Evidence: existing WS3A `EditorNavigationStateMachine` + integration tests remain
  authoritative for reject/pending; find emits only through that path
  (`EditorFindControllerTests.testNavigationAppliesThroughExistingEditorNavigationPath`).
- [x] **Shared navigation ID domain (contract):** production App **must** install
  `EditorFindController.navigationIDProvider` from the same high-water mark as workspace
  search (`AppState.editorNavigationGeneration`). When the provider is nil (unit tests),
  the controller uses a local sequence — safe only while nothing else shares the channel.
  Evidence: `EditorFindControllerLifecycleTests.testNavigationIDProviderUsesSharedDomain`
- Evidence: **closed in PR B for exact-range + provider contract.** Production wiring of
  the provider shipped in merged PR #97 with the App find bar.

### F4 — Edit invalidation

- [x] Editing the document while find is open invalidates the match set and recomputes
  (debounced) against the new revision **without emitting navigation**.
  Evidence: `EditorFindControllerLifecycleTests.testEditRecomputesMatchesWithoutMovingSelectionOrEmittingNavigation`
- [x] A stale match list cannot jump the caret after an edit (session + pending cleared at
  schedule; recompute leaves no navigation command).
  Evidence: same test + `testScheduleMatchInvalidatesSessionSoNextDoesNotUseStaleRanges`
- [x] After edit/rebind (non-navigating recompute), the first next/previous **activates**
  the current ordinal instead of stepping past it.
  Evidence: `EditorFindControllerLifecycleTests.testFirstFindNextAfterRebindActivatesCurrentMatchNotNext`
- Evidence: **closed in PR B**

### F4b — Document lifecycle (defined behavior, not only stale rejection)

F3’s wrong-`documentIdentity` reject is necessary but not sufficient. Preview once
stranded on a previous document when ordering was keyed only on a per-document version
(Decision Log 2026-06-14 `renderID`). Find session state must follow the focused
document explicitly. **Defined v1 behaviors** (bar open unless noted):

| Transition | Intended behavior |
|---|---|
| Sidebar switches to another Markdown/MDX file | Bar **stays open** (merged #97 UI contract). Controller: cancel in-flight work for the old identity; clear matches/ordinal; rebind to the new identity + revision; **re-run the query for the counter only — do not emit navigation / auto-jump**. User moves with `⌘G`. |
| `⇧⌘F` result activates a different document | Same as sidebar switch at the controller: rebind + re-run without auto-jump. Focus arbitration remains F7. |
| External disk change → Reload | Same document identity, new bytes/revision: recompute like F4 edit (**no navigation**); do not apply pre-Reload ranges. |
| External disk change → Keep Mine | Local source remains authority: recompute only if revision/text actually changed; no navigation. |
| Warm session LRU eviction / retirement of a **non-focused** session | No find-session effect while that session is not the focused editor document. |
| Focused session retired / closed / no open document | **Close** the find bar (merged #97 UI contract), cancel work, clear session. |
| Workspace close / switch | Close the find bar and clear session (merged #97 UI contract). |

- [x] PR B named tests cover the **controller half**: file-switch rebind+rerun **without
  navigation emission**, edit recompute without navigation, and clear on no-document —
  without claiming UI bar visibility.
  Evidence: `EditorFindControllerLifecycleTests.testRebindRerunsQueryWithoutEmittingNavigation`,
  `...testEditRecomputesMatchesWithoutMovingSelectionOrEmittingNavigation`,
  `...testClearForNoDocumentCancelsAndClearsSession`
- [ ] Hosted **production-path** tests cover the remaining **UI-visibility half** with
  real Reload / Keep Mine / rename / Save Copy rekey / missing-file close, and cancel on
  the shared navigation channel. Merged #97's App-state and production-lifecycle tests are
  not hosted bar-visibility evidence (see review: External Reload and identity rekey paths
  must invalidate Find).
  Partial unit evidence: `EditorFindUITests.testFindBarStaysOpenAndRebindsOnDocumentSwitchWithoutAutoJump`,
  `...testFindBarClosesWhenNoDocumentRemains`,
  `...testFindBarClosesOnWorkspaceClose`
  Production-path lifecycle evidence (2026-07-27 review):
  `EditorFindLifecycleCombinationTests.testCleanExternalReloadRecountsFindWithoutAutoJumping`,
  `...testKeepMineAfterExternalChangeLeavesFindOnTheLocalSource`,
  `...testRenameRekeysFindIdentityToTheNewURL`,
  `...testDetachedSaveCopyRekeysFindToTheDestination`,
  `...testIndeterminateSaveCopyQuarantineRekeysFindToTheQuarantinedLocation`
  These drive `openExternalFile` / `refreshWorkspaceAfterFileSystemChange` /
  `keepMineForExternallyChangedFile` / `renameWorkspaceItem` / `saveDetachedCurrentDocument`
  rather than the `notifyEditorFind*` hooks, so a hook wired at the wrong point in a
  transaction fails them (the quarantine ordering bug did). They assert controller identity,
  recount, and absence of navigation — **not** hosted bar visibility, which is why the box
  stays unchecked.
- Also covered: a workspace-search activation on the **already-current** document fences an
  in-flight find generation before the search navigation takes an ID
  (`EditorFindReviewFixTests.testWorkspaceSearchHandOffStopsAnInFlightFindFromNavigatingAfterwards`),
  and Escape / Done fences a query still inside the debounce window
  (`...testClosingTheBarFencesAQueryStillInsideTheDebounceWindow`) **without** resetting a
  resolved ordinal (`...testClosingTheBarKeepsTheOrdinalSoTheNextStepAdvances`,
  `EditorFindControllerSuspendTests`).
- Evidence: **partial** — PR B controller half closed; merged #97 covers production-path
  lifecycle + fencing in-process; hosted UI-visibility half still open

### F5 — Reveal without source mutation (WYSIWYG closed in PR B; source+preview still open)

- [x] A match inside a folded WYSIWYG span: navigation selects the match; the fold plan
  recomputed from the **post-navigation** selection marks the region revealed; applying
  that presentation clears folded-delimiter attributes on the delimiter runs; source
  bytes unchanged.
  Evidence: `EditorFindControllerPresentationTests.testExperimentalWYSIWYGFindNavigationSelectsMatchAndRevealsFoldRegion`
- [x] Source text is byte-identical before and after find navigation.
  Evidence: same test + `testSourceOnlyFindNavigationSelectsWithoutSourceMutation`
- [x] Covered with Experimental WYSIWYG both **off** and **on**.
  Evidence: `testSourceOnly...` (off) and `testExperimentalWYSIWYG...` (on)
- [ ] Covered in **source+preview** layout mode with a **live** preview: find navigation
  must move editor selection **and** keep preview scroll sync green via the existing
  scroll proxy (Decision Log 2026-06-25). App-state-only checks that set
  `layoutMode` and assert `EditorNavigationCommand` are **not** sufficient.
  Evidence: _open — needs hosted WorkspaceWindow + PreviewController + scroll coordinator_
- Evidence: **partial in PR B** — WYSIWYG off/on + source identity closed; source+preview
  live path open

### F6 — IME in the find field

- [ ] Composing in the find field must not commit into the document.
- [ ] Escape and Return during marked text belong to the input context (same discipline
  as `MarkdownSTTextView`'s reservation of space / Return / keypad Enter while marked
  text exists). Source-string scans are **not** behavioral evidence.
  Partial behavioural evidence (2026-07-27, second review):
  `EditorFindUITests.testFindQueryFieldCoordinatorLeavesMarkedTextCommandsToInputContext`
  now drives the real `control(_:textView:doCommandBy:)` callback against an `NSTextView`
  with live marked text and asserts neither submit nor close fires. It replaced a
  source-substring scan, which proved nothing and additionally deadlocked the sandboxed
  test host in `open()` once the file's cached sandbox grant went stale.
- [ ] Escape must not reach the bar through any path that outranks the field editor. The
  Done button therefore declares **no** `.keyboardShortcut(.cancelAction)`: a key
  equivalent is resolved before the field editor sees the event, so Escape closed the bar
  mid-composition instead of cancelling it. **Not automated** — reproducing the bypass
  needs a real IME, so this rides the owner IME smoke below.
- [ ] Escape still closes the bar from **every** find context, which removing that key
  equivalent initially broke (it left the query field's delegate as the only handler).
  Restored through two responder-chain routes, neither a key equivalent:
  `MarkdownSTTextView.cancelOperation` → `EditorFindActionHooks.cancelFind` for editor
  focus, and SwiftUI `.onExitCommand` for bar chrome. The editor route defers to marked
  text and to an open completion list first, and falls through to `super` when no bar is
  open so STTextView's own Escape behaviour is unchanged; the chrome route re-checks live
  query-field composition at dispatch, because a field editor that declines
  `cancelOperation:` lets the event bubble past it.
  Evidence: `EditorFindReviewFixTests.testEscapeFromTheEditorClosesTheBarAndReportsItConsumedTheKey`,
  `...testEscapeFromBarChromeClosesTheBar`. Still open: the ordering guarantees against a
  real IME and a real completion list are owner-smoke items.
- Evidence: _open — delegate-level reservation covered; owner physical IME still required
  for commit-into-document and the Escape-during-composition path_

### F7 — Focus arbitration with ⇧⌘F

- [ ] Sequence `⌘F` → `⇧⌘F` leaves focus somewhere sane every time (find field,
  workspace-search field, or editor — never a dead control); older Find focus closures
  must not steal after a newer intent (key-window only, request-token ordered).
- [ ] Neither feature's focus receipt is consumed by the other (token independence is
  necessary but not sufficient — first-responder proof required).
- [ ] Find focus tokens are independent of `WorkspaceSearchUIState` request/applied IDs.
  Partial: `EditorFindUITests` token integer tests.
- [ ] A focus request consumed by one `WindowGroup` window is not replayable by another
  window or by a remounted bar. Partial (2026-07-27 review): `EditorFindUIState` now carries
  an App-owned `focusAppliedID` alongside `focusSupersededID`, arbitration is pure
  (`EditorFindFocusArbitration`), and the owned field's attempt is a bounded key-window retry
  instead of one `DispatchQueue.main.async` hop that lost the first-⌘F mount race.
  Evidence: `EditorFindFocusReceiptTests.testFocusReceiptIsSharedSoASecondWindowCannotReplayASpentRequest`,
  `...testBackgroundWindowAndSupersededRequestsNeverAdvanceTheReceipt`,
  `...testRetryContinuesWhileTheBarIsVisibleAndTheRequestIsUnresolved`.
  The **select-all** receipt is App-owned for the same reason
  (`...testSelectAllReceiptIsSharedSoASecondWindowCannotReplayIt`): a coordinator-local one
  starts at zero in a new window, so a spent select-all would replay and the next keystroke
  would replace the whole query.
  Still open: hosted dual-window first-responder proof (the WS3C `WindowKeyStateTracker`
  equivalent), which is what actually closes this gate.
- [ ] Find commands stay eligible while Full Keyboard Access focuses a bar control (Aa,
  whole-word, Next, Previous, Done). The bar's own controls act unconditionally; menu
  eligibility comes from SwiftUI-reported `EditorFindChromeFocus`, **tagged with the
  reporting window** and accepted only when that window is key — `AppState` is shared
  across the `WindowGroup`, so an untagged report let focus stranded in a background window
  grant eligibility in the key one. Partial: `EditorFindFocusReceiptTests`
  `testFindBarChromeFocusKeepsMenuCommandsEligibleOnlyForTheHostingKeyWindow`,
  `...testKeyWindowChangeAloneFlipsChromeFocusEligibility`,
  `...testEveryBarCloseRouteClearsReportedChromeFocus`,
  `...testFindBarControlsActEvenWhenTheResponderGuardWouldRejectTheContext`. Only *which
  window is key* is stubbed; the report-versus-key comparison runs for real.
  Storage is **one entry per window** (`chromeFocusByWindow`), so neither clearing nor
  overwriting can cross windows and returning to a window whose bar still holds focus restores
  eligibility with no republication
  (`...testBackgroundWindowCannotClearTheKeyWindowsChromeFocusReport`,
  `...testBackgroundWindowCannotOverwriteTheKeyWindowsChromeFocusReport`,
  `...testSwitchingBackToAWindowThatAlreadyReportedFocusRestoresEligibility`). The window
  itself is published a turn late by `EditorFindBarWindowBridge` rather than written into
  `@State` from `updateNSView`, with generation fencing so a superseded attachment cannot
  publish (`...testWindowBridgeDefersPublicationToTheNextMainActorTurn`,
  `...testWindowBridgeAttachThenImmediateDetachNeverPublishesTheStaleWindow`,
  `...testWindowBridgePublishesOnlyTheLatestOfARapidSequence`,
  `...testWindowBridgeDismantleDetachesTheProbe`).
  Still open: hosted Full-Keyboard-Access run — in-process tests cannot produce the real
  SwiftUI focus transition, so nothing here proves SwiftUI reports the focus at all, nor that
  the bridge receives a window in the shipped view tree.
- [ ] `⌘F` while the find bar is **already open** re-focuses the owned query field,
  selects all existing query text, and **never closes** the bar — proven on a real
  first responder, not only focusRequestID counters.
  Evidence (2026-07-29):
  `EditorFindAcceptanceTests.testRepeatedCommandFRefocusesSelectsAllAndLeavesBarOpen`
  launches the app, opens Find with `⌘F`, moves native keyboard focus back to the editor,
  immediately reasserts that the bar is still present and its query is still `needle`,
  then sends a second `⌘F`. Predicate waits observe the query field regain native
  `hasKeyboardFocus`; pasting `q` without a test-side select-all replaces the whole existing
  `needle` query, and the launched app still exposes `plainsong.editorFind.bar`.
- Evidence: _implementation complete; the pre-strengthening launched-app artifact proves
  first-responder refocus/replacement, but the exact-tree 3× run for the added retained-query
  assertion remains pending after two unlocked attempts executed zero product tests because the
  runner timed out enabling automation mode. The cross-feature, dual-window, and Full Keyboard
  Access hosted matrix also remains open._

### F8 — Highlight-all survives highlight re-application

- [ ] If highlight-all is implemented, find-match attributes survive
  `applyHighlightedText` / visible-range recompute the same way image presentation
  markers do.
- [ ] Named test applies highlighting **between** search attribute application and the
  assertion (proves preservation, not just initial paint).
- [ ] If highlight-all is deferred out of v1, this gate stays open and the separate F8
  follow-up must say so explicitly rather than checking the box.
- Evidence: _open — separate pending F8 follow-up (or explicit deferral)_

### F9 — Accessibility + XCUITest

- [x] Stable accessibility identifiers under `plainsong.editorFind.*` for the bar,
  query field, case/whole-word controls, match counter, next/previous controls, and
  **truncated-state** indicator (when `isTruncated` is set after a
  `retainedMatchCeiling + 1` overflow).
- [x] Match counter’s truncated presentation is distinct from an exact total (not
  color alone).
- [ ] `PlainsongUITests` asserts that `⌘F` while the bar is already open re-focuses the
  query field, selects its text, and leaves the bar open (never closes) — out of
  process, following the WS4A fixture pattern.
- [x] `PlainsongUITests` coverage following the WS4A fixture pattern: app-container
  fixture, predicate waits, no `NSOpenPanel` automation, synthetic events only (not F0
  evidence).
- Evidence (2026-08-08): `EditorFindAcceptanceTests` launches the Debug app against a unique
  app-container-owned `editor-find.md` fixture and enters the production workspace-open path.
  Three separate methods cover the gate. The repeated-`⌘F` test predicate-waits for the bar
  to be absent, proves the first shortcut opens and focuses it, enters `needle`, blurs the
  query field, and — at the immediate pre-injection boundary of the second shortcut — asserts
  that the same bar still exists and still contains `needle`. It then proves production
  refocus, reasserts the retained `needle` query after focus returns, proves select-all by
  typing a replacement without issuing a test-side select-all, and verifies that the bar
  remains open. The counter test distinguishes exact `1 / 3` with no
  truncated element from `… / 10000+` plus the stable truncated identifier and its
  non-color-only accessibility value. The chrome test verifies the query/toggle/button AX
  roles, empty-query enabled states, case and whole-word value/count transitions,
  Previous/Next ordinal changes, and Done closing the bar with editor focus restored.
  The last successful three-iteration command before the final test-only strengthening
  `xcodebuild test -project Plainsong.xcodeproj -scheme Plainsong
  -destination 'platform=macOS,arch=arm64' -derivedDataPath
  /private/tmp/plainsong-f9-review-dd-20260808 -resultBundlePath
  /private/tmp/plainsong-f9-review-f9-ui-3x-20260808a.xcresult
  -only-testing:PlainsongUITests/EditorFindAcceptanceTests -test-iterations 3`
  passed all 9 launched-app test runs with no failure or skip. Every run completed the exact
  nonce-bound app-side cleanup handshake before termination. That artifact proves the
  immediate pre-second-shortcut `needle` check plus refocus/select-all replacement, but it
  predates the final additional assertion that `needle` is still retained after refocus and
  immediately before replacement. Two exact-tree three-iteration attempts retained at
  `/private/tmp/plainsong-f9-review-f9-ui-strengthened-3x-20260808a.xcresult` and
  `/private/tmp/plainsong-f9-review-f9-ui-strengthened-3x-20260808b.xcresult` each executed zero
  product tests: the locked macOS console made `PlainsongUITests-Runner` fail initialization
  with `Authentication canceled. System authentication is running.` Those are runner/
  automation failures, not assertion failures. After the final responsibility split, two more
  exact-tree 3× attempts started with `IOConsoleLocked = No` but likewise executed zero product
  tests: `/private/tmp/plainsong-f9-final-tip-ui-3x-20260808.xcresult` and its `b` retry both
  report `Timed out while enabling automation mode.` A successful exact-tree 3× execution
  remains the final launched-app evidence gap for the strengthened contract.

  Fixture creation acquires and locks a root-anchored, exclusive, no-follow per-run lease
  before publishing the workspace name. The retained app-side handle holds the workspace
  directory descriptor plus a random ownership-marker descriptor/inode created inside that
  workspace, then persists that workspace and marker device/inode binding in the locked lease.
  Cleanup fails closed if the captured root/workspace is missing, renamed, or swapped. The
  exact captured workspace is first moved under the root to a random quarantine name; its
  workspace and marker identity is re-proved there before recursive removal, so a lexical
  replacement at the published name cannot inherit deletion authority. The marker link must
  reach zero, the retained directory path is checked with `F_GETPATH`, and no-follow absence at
  the exact recorded quarantine name is required before the exact lease is removed and a receipt
  can be published. Once those retained-handle checks prove that quarantine was removed, a new
  same-name occupant at the published workspace path is unrelated and survives retry. The UI
  runner receives neither a path nor deletion authority. The one-hour
  crash/interruption sweep reclaims only an expired fixture whose released lease it can lock
  **and** whose persisted workspace/marker binding still matches; a lexical same-name
  replacement and a live/paused run remain protected. Initial orphan-lease inspection carries
  the captured inode through descriptor validation, so an entry swapped between `lstat` and
  `open` cannot inherit stale-unbound deletion authority. Released pre-workspace leases remain
  reclaimable only while exact and unbound; bound missing-name/corrupt leases and unleased
  legacy entries fail closed.

  Lease rename/unlink retry state is recorded before each mutating syscall. If a rename or
  unlink succeeds and a following sync/root revalidation throws, retry reconciles the exact
  random quarantine destination plus the retained descriptor's identity/link count; it does
  not treat a missing lexical source as success. Before ownership-marker unlink, live workspace
  cleanup re-enumerates a partially emptied quarantine; its regression fixes child order and
  proves named children were removed before the injected first failure. Marker-unlink intent is
  likewise recorded on the retained workspace handle immediately before the syscall. Success is
  accepted only when the exact retained marker descriptor has link count zero and the no-follow
  marker path is absent. A live retry and the stale sweep's same invocation can then reuse that
  exact workspace/marker handle. Once marker removal is verified, retry requires the exact
  quarantine to be empty and does not recursively delete any newly appeared occupant.

  Current-tree focused fixture/lease coverage passed 46/46 with no failure, skip, or runtime
  warning in `/private/tmp/plainsong-f9-final-split-fixtures-20260808.xcresult`. It includes
  deterministic initial-inspection swaps, live/stale replacement sentinels, post-rename and
  post-unlink throw/retry, remove-then-throw recovery, rename-away, live-lease preservation,
  deterministic pre-marker partial-removal retry, live retained-handle post-marker retry, and
  stale same-invocation post-marker retry. The latter two prove exact quarantine and lease
  removal while published-name and fixture-root sentinels remain byte-for-byte intact. A live
  post-rmdir regression additionally creates a same-name published replacement after the exact
  quarantine removal and injected throw; retained-handle retry removes only the owned lease and
  preserves that replacement plus the root sentinel. A separate regression creates a replacement
  at the removed marker name, re-expires the quarantine before the later sweep, observes the exact
  stale binding-rejection boundary, and proves that both sweeps preserve the marker, bound
  quarantine, lease, and root sentinel. Earlier nine
  launched-app runs each verified their exact nonce-bound app-side receipt and `notRunning`;
  read-only host inspection found every current-run fixture ID absent. A separate concurrently
  running F9 fixture kept its open lease and survived the stale sweep, then its owning app removed
  it; the fixture root was empty afterwards. The Debug fixture implementation is split along
  creation/live-cleanup, lease-binding/lease-operation, quarantine-naming/root-I/O, and retained-
  workspace-authority/anchored-I/O seams; the resulting production files are 101–375 lines. The
  removal-race regression suite is likewise split by retry, stale-marker, lease-quarantine, and
  shared-support responsibility, with files of 48–348 lines.

  Cleanup traffic uses a per-run named pasteboard. General-pasteboard shortcut text captures
  the item-ordered type/data byte mappings observable through AppKit before mutation and retains
  ownership only when readback has both those exact bytes and the helper-owned generation. A
  distinct external generation observed at a checked boundary is preserved. A failed restore
  remains retryable after app termination; exact owned bytes at the helper's generation retain
  restoration authority even when AppKit reports write failure, while an owned clear retains
  only its exact empty generation. Originally empty pasteboards restore through that clear
  generation. AppKit exposes no getter for active pasteboard contents options, so the evidence
  does not claim restoration of an unobservable option such as `currentHostOnly`. Focused
  restoration coverage passed 24/24 by direct `xctest` execution (10 TIS + 14 pasteboard),
  including input-source readback mismatch retry and identical-byte/new-generation pasteboard
  ABA rejection. AppKit offers no atomic pasteboard
  compare-and-swap, leaving a documented final check-to-clear micro-race; `nil` items with
  advertised types fail closed, while `nil`/`nil` is accepted as an observably empty
  pasteboard and cannot distinguish total retrieval failure.

  Synthetic textual shortcuts discover current → recent ASCII → enabled ASCII-list sources
  and require keyboard category, enabled, select-capable, and ASCII-capable properties.
  Selection and exact-source restoration are read back; a distinct external source observed at
  a checked boundary is preserved, while a failed helper-owned restore remains retryable
  immediately and after app termination. TIS offers no compare-and-swap, so a change in the
  final read-to-select window and same-ID ABA are not observable ownership guarantees.
  Capability-policy tests admit British, Dvorak, and Colemak without an identifier allowlist;
  the launched-app run itself used ABC, so no alternate-layout launch matrix is claimed. A hard
  runner-process death can still bypass TIS/general-pasteboard teardown. The retained F9
  artifact contains nine QoS-inversion and nine SwiftUI state-during-view-update runtime
  warnings with no file/line root-cause attribution; it does not support assigning existing
  `WorkspaceWindow` warnings to this branch.

  No full `make test` invocation is green. An earlier ordinary invocation stopped in its
  first Swift package at the existing MarkdownCore
  `TextSearchResourceBoundTests.testOneMegabyteContinuousUnicodeWordSkipsRejectedCandidatesLinearly`
  assertion: 3.086859833 seconds exceeded the 3-second local budget. Its exact isolated rerun
  also failed at 3.045512125 seconds. A separate `CI=1 make test` treated the MarkdownCore
  measurement as informational, then exited during Xcode testing after one WorkspaceKit
  assertion failure among 283 tests; the retained output did not preserve the failing test
  identifier, so no narrower attribution is claimed, and Make did not reach preview. A fresh
  ordinary invocation on the reviewed tree then passed all four Swift package suites; its
  Xcode phase passed 642 tests with one skip, but the sole failed entry was
  `PlainsongUITests-Runner` initialization before any UI assertion because macOS reported
  `Authentication canceled. System authentication is running.` Xcodebuild exited 65, Make
  exited 2, and Make again did not reach preview. A separate Xcode rerun excluding only
  `PlainsongUITests` passed the same 642 tests with one skip and zero failures in
  `/private/tmp/plainsong-f9-review-nonui-20260808a.xcresult`. Separate launched-app reruns
  passed WorkspaceSearch acceptance 2/2 and pre-strengthening F9 9/9, but those focused
  results do not recharacterize any full `make test` invocation as green. The latest exact-tree
  invocation again completed all four Swift package stages and reached Xcode testing. The
  terminal record shows the 23 performance tests passing with zero failures, but Xcode then
  crashed while writing the test result's system-log archive
  (`CASTreeDataStructure/Importer.swift:135`, `Unable to write data ... due to ioError`);
  `make test` exited 2 with `Trace/BPT trap: 5`. The volume had only about 105 MiB free, so this
  is recorded as an xcresult-finalization I/O failure under ENOSPC-level disk pressure, not a
  product assertion and not a green full-suite run. The incomplete 297 MiB result bundle from
  that invocation was removed; no unrelated DerivedData or retained evidence was deleted. All
  four Swift package stages in the current review-fix invocation passed, as did the Xcode phase's
  646 tests with one skip and the displayed 23/23 performance tests. Its only failed xcresult
  entry was again `PlainsongUITests-Runner` initialization before any UI assertion while
  `IOConsoleLocked = Yes` (`Authentication canceled. System authentication is running.`);
  Xcodebuild exited 65, Make exited 2, and Make did not reach preview. This is a locked-console
  automation failure, not a product assertion and not a green full-suite run. The final split
  tree's `make test` again passed all four Swift package stages and 646 Xcode tests with one skip,
  including 23/23 performance tests. Its only failed xcresult entry was
  `PlainsongUITests-Runner` launch before UI assertions (`LaunchServices` error `-600`);
  Xcodebuild exited 65, Make exited 2, and Make did not reach preview. This remains a runner/
  automation failure and not a green full-suite run. All
  F9 state waits are
  predicate-based; no
  `NSOpenPanel` is used. Synthetic XCUI `typeKey` evidence is not physical-keyboard or IME
  evidence. On macOS
  there is no descriptor-bound conditional `rmdir`; the marker + descriptor-path checks cover
  the app-owned/cooperative and tested rename/swap cases but are not an identity-atomic
  guarantee against a hostile same-container actor racing marker unlink and final path checks.
  A crash in the small mkdir/marker-to-lease-binding window can conservatively strand an unbound
  fixture. A process exit after marker unlink but before exact quarantine removal loses the
  retained descriptors and handle-local unlink attempt; a later sweep therefore preserves the
  bound-but-no-longer-marker-verifiable quarantine and its lease. Recovery across that boundary
  would require a durable, fsynced progress record. These cases leak Debug fixture bytes rather
  than broadening deletion authority or publishing a false receipt.
  `project.yml` is unchanged; XcodeGen only refreshed source inventory for the folder-backed
  test/app targets, and the generated project was not hand-edited. F9 and only the repeated-
  `⌘F` sub-gate of F7 are the scope of this branch; a successful exact-tree 3× run remains
  the only current F9 launched-app assertion-evidence gap, while the unsuccessful full
  `make test` is a separate validation gap. F2 retains only its separately named proxies, F8
  stays separate and pending, and no combined-tip evidence is claimed.

## 9. Performance gate (separate F2 follow-up)

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
| Owner | **F0 physical-keyboard spike at the start of PR B** under ABC + Zhuyin (menu route first; Carbon only if that fails); merge authority. F0 is not deferred to a later performance follow-up. |
| Maintainer | Squash-merge after review + green CI; never author self-merge. |
