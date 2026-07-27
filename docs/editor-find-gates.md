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

- `⌘F` toggles a find bar owned by the focused editor in the key window.
- `⌘G` / `⇧⌘G` move to next / previous match with wrap-around at both ends
  (Typora behavior; agent.md §17.12).
- `⌘E` uses the current selection as the find pattern (when non-empty and valid).
- Escape closes the find bar and returns focus to the editor.
- Match counter shows current ordinal / total (or an empty / no-match state).
- Case-sensitivity and whole-word toggles match the workspace-search model
  (smart/sensitive/insensitive + Unicode whole-word).
- Navigation selects and reveals exact UTF-16 ranges through the existing
  `EditorNavigationRequest` / `EditorNavigationCommand` path — never a second
  selection/scroll channel.
- Find **never mutates source text**. Selection and reveal only.

Workspace search (`⇧⌘F`) remains independent. Neither feature's focus receipt may
consume the other's token.

## 2. Baseline: what ⌘F does today (code-verified; F0 still open)

Empirical code inspection on the PR A tip (not a physical-keyboard run):

| Observation | Evidence |
|---|---|
| STTextView ships a full `NSTextFinder` stack | `STTextView` init constructs `textFinder`, `STTextFinderClient`, and `STTextFinderBarContainer`; `performFindPanelAction` / `performTextFinderAction` forward to `textFinder.performAction` (`STTextView+Find.swift`). |
| `MarkdownSTTextView` does not override find | EditorKit subclass never touches `textFinder`, find actions, or the bar container. |
| Editor is hosted in `NSScrollView` | `MarkdownTextView.makeNSView` uses `MarkdownSTTextView.scrollableTextView()`, so the bar container has a scroll view to attach to. |
| Plainsong does not claim `⌘F` | `PlainsongCommands` claims `⇧⌘F` (Toggle Workspace Search) and Format Table is `⌥⌘F`. No Edit ▸ Find items are declared by the app. |
| Carbon hot key matches exact `cmdKey\|shiftKey` | `PlainsongMenuKeyBinding` / `PlainsongApplication` register only ⇧⌘F; plain ⌘F is intentionally unclaimed (Decision Log 2026-07-22). |
| System Edit ▸ Find can reach the first responder | When the editor is first responder, AppKit's standard Find menu items send `performTextFinderAction:` / `performFindPanelAction:` down the responder chain into STTextView's built-in finder. |

**Conclusion for implementers:** a working built-in `NSTextFinder` path already exists
when the editor is focused. **This work replaces that path.** PR B/C must disable the
built-in finder (so two find UIs cannot coexist) and own ⌘F / ⌘G / ⇧⌘G / ⌘E through
Plainsong menus + the focused-editor responder chain. State the replacement explicitly
in every PR body that touches behavior.

F0 still requires **owner physical-keyboard** verification under ABC and Zhuyin before
and after the replacement. Synthetic `NSEvent`s and XCUITest input are **not** F0
evidence (Decision Log 2026-07-22).

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
| `⌘F` | Toggle find bar for the focused editor in the key window. Opening focuses the owned find query field; a second press while the bar is open may re-focus the field (implementation choice, fixed in PR C with a test). No-op when focus is not an editor that can find (sidebar, preview, no document). |
| `⌘G` | Next match from current ordinal (or from caret anchor when no current match). Wraps last → first. |
| `⇧⌘G` | Previous match. Wraps first → last. |
| `⌘E` | Use non-empty selection as the find pattern when it is a valid literal (≤ 256 UTF-16, no newlines); otherwise no-op or surface validation without mutating the document. |
| Escape | Close find bar; return focus to the editor. Does not clear document selection unless product copy later says otherwise — default: leave the last navigated selection. |
| Case toggle | UI default mirrors workspace search: smart case; Aa forces sensitive; explicit insensitive remains model-capable even if the first chrome is a single toggle over smart. |
| Whole-word | Independent Unicode whole-word flag (same word characters as workspace search). |
| Match counter | `current / total` when `total > 0`; distinct empty-query and no-match states. |

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
6. **Disable the built-in finder** so STTextView's `NSTextFinder` bar cannot appear
   alongside Plainsong's bar.

### 5.4 UI patterns to reuse (WS3C)

- Owned AppKit `NSTextField` for the find query (SwiftUI `FocusState` was rejected in
  WS3C PR A for the search field).
- Pure selection / ordinal reducer for next/previous (testable without AppKit).
- Stable accessibility identifiers under a `plainsong.editorFind.*` namespace.

## 6. Architecture sketch (non-binding names; capabilities are binding)

### 6.1 MarkdownCore — find session (PR B)

Pure value types over `TextSearchEngine` results, for example:

- query + options → `[TextSearchMatch]` (engine already owned)
- session state: matches, current ordinal (1-based UI), last caret anchor UTF-16
- pure functions: `next(from:)`, `previous(from:)`, `ordinal(nearestTo:preferring:)`,
  wrap-around at both ends, empty / oversized / newline / zero-match handling

No I/O, no actors, no AppKit.

### 6.2 EditorKit — search controller (PR B)

- Observe document text / revision (existing session publication, not
  `objectWillChange` on every keystroke).
- Debounce query changes; cancel in-flight match Tasks; run
  `TextSearchEngine.matches` off the main actor.
- Fence completions by `(documentIdentity, sourceRevision, queryGeneration)`.
- Emit `EditorNavigationCommand.navigate` with a new monotonic ID for every
  next/previous/activate — including re-activating the same match — so the WS3A
  state machine never treats a legitimate re-selection as a stale ID.
- Optional highlight-all attribute application with the same preservation contract as
  image markers (F8 may land in PR D).

### 6.3 App — find bar + menus (PR C)

- Find bar chrome above or below the focused editor pane (implementation detail;
  prefer not fighting the STTextView gutter / scroll geometry).
- Menu items: Find, Find Next, Find Previous, Use Selection for Find — responder-chain
  routed.
- Focus intents independent of `WorkspaceSearchUIState` tokens.
- Built-in `NSTextFinder` disabled at editor construction / find enablement.

### 6.4 Performance probe (PR D)

Add a `PerformanceTests` probe over `Fixtures/large-1mb.md`:

1. Measure first (Debug and Release), at least three runs each.
2. Record numbers in `docs/perf-log.md`.
3. Freeze the budget from measured Debug medians (same discipline as WS4B).
4. Do not invent a budget; do not widen a budget to rescue a failing run.
5. Wall-clock budgets are hard locally and informational on hosted CI under R15.

## 7. PR split

One review-sized PR each. Branch naming: `phase3-editor-find-<slug>`. PRs against
`main`. Maintainer squash-merges. Never push to `main`, never merge your own PR.

| PR | Scope | Gates closed |
|---|---|---|
| **A** (this PR) | Spec only: this file + Decision Log engine entry. No behavior change. | none (documents F0–F9 open) |
| **B** | MarkdownCore find-session model + EditorKit search controller (off-main, debounced, cancellable, revision-fenced) navigating through existing navigation API. Disable built-in finder enough that controller ownership is exclusive. **No App find-bar UI.** | F1–F5 (named tests) |
| **C** | App find bar UI + menu items + focus arbitration with ⇧⌘F. F6 IME in find field; F7 focus arbitration. | F6, F7 |
| **D** | XCUITest (F9), performance probe with frozen budgets, highlight-all + F8, owner physical-keyboard F0 sign-off. | F0, F8, F9 + perf |

Before declaring any PR done: `make format && make lint && make test && make build`,
and `git diff --check`. PR body must list which F-gates it closes and which remain
open. Check a gate box only with named-test evidence.

## 8. Gates

Checkboxes start unchecked. Evidence lines are filled when the gate closes.

### F0 — ⌘F key delivery (owner physical keyboard)

- [ ] Ordinary menu-item route delivers Find under **ABC** and **Zhuyin** on a
  **physical** keyboard. Prefer the menu-item / standard key-equivalent path first.
- [ ] Do **not** preemptively add a second Carbon hot key registration. Fall back to the
  `PlainsongMenuKeyBinding` / app-active Carbon pattern **only** if physical delivery
  actually fails, and record the evidence either way.
- [ ] Synthetic `NSEvent`s and XCUITest input are **not** evidence for this gate
  (Decision Log 2026-07-22).
- Evidence: _open — owner run required in PR D_

### F1 — Pure find-session model

- [ ] Ordinal is well-defined for zero, one, and many matches.
- [ ] Next / previous from an arbitrary caret anchor select the correct match.
- [ ] Wrap-around at both ends (last→first, first→last).
- [ ] Empty pattern, oversized pattern (&gt; 256 UTF-16), and newline-containing
  patterns yield no matches (engine rules) and a defined session empty state.
- [ ] Single-match next/previous is stable (stays on the only match; still emits a fresh
  navigation ID at the controller layer — covered under F3).
- Evidence: _open — PR B MarkdownCore tests_

### F2 — Off-main, debounced, cancellable

- [ ] Match work runs off the main actor; query changes cancel in-flight work.
- [ ] Results are fenced by document revision / query generation; stale completions do
  not apply.
- [ ] Typing latency on `Fixtures/large-1mb.md` is unchanged with the find bar open and
  a live query (no main-actor full-document match on the keystroke path). §12 &lt; 16 ms
  typing budget remains the hard product gate; the dedicated find perf probe is PR D.
- Evidence: _open — PR B EditorKit tests (+ latency statement)_

### F3 — Exact UTF-16 navigation through EditorNavigationRequest

- [ ] Activating a match selects the exact half-open UTF-16 range and reveals it.
- [ ] Repeated activation of the **same** match works (monotonic navigation IDs).
- [ ] Stale requests (older ID, wrong document identity, invalid range, marked text /
  not-installed) are rejected without clamping.
- Evidence: _open — PR B EditorKit navigation tests_

### F4 — Edit invalidation

- [ ] Editing the document while find is open invalidates the match set and recomputes
  (debounced) against the new revision.
- [ ] A stale match list cannot jump the caret after an edit.
- Evidence: _open — PR B_

### F5 — WYSIWYG reveal without source mutation

- [ ] A match inside a folded WYSIWYG span reveals that span via the existing
  navigation / reveal path.
- [ ] Source text is byte-identical before and after find navigation.
- [ ] Covered with Experimental WYSIWYG both **off** and **on**.
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
  query field, case/whole-word controls, match counter, and next/previous controls.
- [ ] `PlainsongUITests` coverage following the WS4A fixture pattern: app-container
  fixture, predicate waits, no `NSOpenPanel` automation, synthetic events only (not F0
  evidence).
- Evidence: _open — PR D_

## 9. Performance gate (PR D)

| Step | Rule |
|---|---|
| Measure first | Probe real find over `Fixtures/large-1mb.md` through the production controller path (or the nearest production-shaped API). |
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
| Owner | F0 physical keyboard under ABC + Zhuyin; merge authority. |
| Maintainer | Squash-merge after review + green CI; never author self-merge. |
