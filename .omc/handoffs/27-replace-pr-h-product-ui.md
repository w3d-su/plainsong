# Handoff 27 — Replace PR H: product UI, menus, focus and deterministic IME (R8 + R6 deterministic half)

Read `06-phase3-parallel-overview.md` first, **including its update blocks**: the worktree rule,
the shared xcodebuild lock, the pinned lint, the Decision Log location, and "dev Mac is never
idle".

## Preconditions and where you work

- **Start only after #145 (Replace PR G, Replace All) is merged to `main`.**
  - Replace PR H builds the UI on G's plain results, progress values, and Cancel.
  - Single Replace (#137), App authorization (#131) and the Find navigation-ownership fix (#146) are already on main.
- **Worktree:**
  ```sh
  cd /Users/davis._.su/Documents/blogeditor && git fetch origin
  git worktree add ../plainsong-replace-ui -b phase3-editor-replace-ui origin/main
  cd ../plainsong-replace-ui && git branch --unset-upstream 2>/dev/null; make generate
  ```
- **Read first:**
  - `agent.md`:
    - §6.1 (no STTextView in App);
    - §6.4 (shortcut table: `⌥⌘F` is Format Table, `⌘E` is Use Selection for Find);
    - §12, §13 (IME is non-negotiable), §17.
  - `docs/editor-replace-gates.md`:
    - **§5.1**: the bar layout, every command and control, eligibility, and the chrome lifecycle table;
    - §5.2–§5.6;
    - **§5.5** (the three marked-text owners);
    - §6.3, §7 row **H**;
    - gates **R6** (the deterministic bullets only) and **R8**;
    - the R7 / PR E notes on the transient `externalObservationPending` refusal (it must be shown as a transient blocked state, not a failure).
  - `docs/editor-find-gates.md`: F6/F7 (focus receipts, key window, Full Keyboard Access) and the hosted gate patterns.
  - `docs/decision-log.md`: the rows for Replace PR D/E/F/G, #142 and #146.

## What exists (verify on main after #145)

- **EditorKit:**
  - `EditorReplaceCommandDispatcher` (single Replace) and the batch dispatcher;
  - plain outcome and refusal types;
  - the batch executor with progress and cancel.
- **App:**
  - `performEditorReplace(...)` and the Replace All entry points, with their typed results (Cancel distinct after the 19a fixes);
  - `EditorReplaceAuthorizationDecision`;
  - the authority generation;
  - `EditorReplaceMarkedTextOwners`, which has a pluggable **third owner** waiting for the replacement field;
  - the Find bar (`App/Views/EditorFindBar.swift`) and query field (`EditorFindQueryField.swift`), with focus receipts, `focusRequestID` / `focusAppliedID` / `focusSupersededID`, and per-window chrome focus.
- **Seams G left for this PR:**
  - the "collapse" supersession seam;
  - user-visible text for "Changed X of Y" and "No changes";
  - overflow and blocked text.

## Scope (§7 row H, §5.1)

1. **The bar.**
   - The existing Find row becomes the first row of a compact `VStack`, and a disclosure reveals a second row. The second row contains:
     - one **owned AppKit single-line `NSTextField`** for the replacement (no SwiftUI `TextField`, so marked-text ownership stays observable);
     - **Replace** and **Replace All** buttons;
     - a progress/status label with an explicit **Cancel** while a plan is preparing.
   - **Replacement value:** empty is valid (it deletes). The value is literal, with no escape expansion, and single-line, with literal newlines rejected.
   - **Length limit:** more than 256 UTF-16 code units shows an explicit field error and disables both actions.
2. **Menus** (Edit menu, no new global shortcut, `⌥⌘F` stays Format Table):
   - **Find and Replace…:** shows and expands the bar, then focuses the query with select-all through the *existing* query-focus receipt. Tab or click reaches the replacement field without a competing async focus token.
   - **Replace** and **Replace All:** eligible only while the bar is visible **and** the row is expanded. They are eligible from either owned field editor. Use the same key-window responder eligibility as Find, and reach only the key window's installed editor, with no fallback to another window.
3. **Existing commands keep their behavior:**
   - **`⌘F`:** shows or refocuses the bar and selects the query. It never collapses the row, and it cancels any pre-commit plan.
   - **`⌘E`:** changes only the query.
   - **`⌘G` / `⇧⌘G`:** unchanged, and they never mutate.
   - **`⇧⌘F`:** supersedes the pending find focus, cancels the plan, and never consumes receipts.
4. **Return and Escape:**
   - **Return in the replacement field** runs Replace only when no marked text exists.
   - **Escape** gives marked text first refusal, then closes the bar and cancels the plan.
5. **Lifecycle:** implement the §5.1 transition table exactly:
   - Escape/Done;
   - collapse, which cancels the plan, makes the menus ineligible, and keeps the value;
   - file switch and workspace-search activation;
   - Reload / Keep Mine / rekey;
   - no document;
   - workspace close or switch.

   Hidden retained replacement text can never execute.
6. **States and accessibility:**
   - **Spoken, non-color-only states:**
     - progress ("Preparing n / total");
     - "Applying…";
     - blocked, including the transient `externalObservationPending` window;
     - overflow ("More than 10,000 matches; narrow the search");
     - "No changes";
     - "Changed X of Y matches";
     - per-reason refusals.
   - Stable identifiers under `plainsong.editorFind.*` for: disclosure, replacement field, Replace, Replace All, progress, Cancel, blocked reason, and overflow.
   - **Full Keyboard Access** reaches every control.
7. **The third marked-text owner.** Plug the replacement field into `EditorReplaceMarkedTextOwners`, so that both of these refuse with zero effect while it composes:
   - single Replace;
   - Replace All's final pre-commit recheck.

**Out of scope:**
- the owner real-IME harness and R9/R10 acceptance (PR I);
- new global shortcuts;
- multiline replacement;
- regex.

## Gates (named tests only)

- **R8: every bullet.**
  - Hosted App tests drive real controls and menus through the production dispatchers.
  - Include the menu-eligibility matrix: bar hidden, row collapsed, either field focused, a background window, a remounted bar replaying a stale token.
- **R6, deterministic bullets 1–4.**
  - Use synthetic marked text in each of the three owners (editor, query field, replacement field).
  - Assert:
    - refusal before navigation, reveal, authorization, undo, progress or ordinal change;
    - Return and Escape defer to the input context;
    - after composition, a fresh explicit action is required;
    - marked text that begins during Replace All planning invalidates the action at the final recheck.
  - **Leave R6's owner-run Zhuyin/Pinyin bullets open.** Prepare the opt-in harness command for PR I.
- Leave R9 and R10 open. Update the `docs/editor-replace-gates.md` status header and evidence.
- One Decision Log row covering:
  - the field implementation (AppKit `NSTextField` and why);
  - the menu placement;
  - the blocked-state presentation;
  - the collapse seam.
- Update `agent.md` §6.4 with the three new Edit-menu items (no shortcuts). That is the only `agent.md` edit allowed.

## Verification

- `swift test` for MarkdownCore and EditorKit.
- Hosted, under the lock:
  - all `EditorFind*` and `EditorReplace*`;
  - the F6/F7 focus gates;
  - workspace-search focus and activation suites.
- XCUITest only if needed for menus. Those tests need a foreground interactive session; see the memory "UI tests need a foreground app".
- `make build`, pinned `make lint`, `git diff --check`, files of ~400 lines or fewer.
- **Typing path:** nothing new per keystroke in the editor. If the replacement field's change handling touches the authority generation, prove it does not run on editor keystrokes.

Recommended model: **Opus** (focus arbitration, responder chains, IME).

PR title: `Phase 3 Replace PR H: product UI, menus and deterministic IME (R8, R6 deterministic)`.
