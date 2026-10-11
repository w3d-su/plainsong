# Handoff 27b — #151 (Replace PR H): fix the CI failures in the new hosted Replace-row tests

Read `06-phase3-parallel-overview.md` first, **including its update blocks**: shared lock,
pinned lint, "dev Mac is never idle", and the memory notes "hosted tests need an unlocked
screen" and "Open CI flakes". Then read `27-replace-pr-h-product-ui.md` and
`25-find-navigation-cancelled-race.md`. Handoff 25 shows the method that root-caused
"failure A" for the Find gates; reuse it.

## Where you work

- **PR:** #151, `Phase 3 Replace PR H: product UI, menus and deterministic IME`.
- **Worktree:** `/Users/davis._.su/Documents/plainsong-replace-ui`, branch
  `phase3-editor-replace-ui`, head `b157e38`. This head is a merge of `origin/main` at
  `b13aa62` and is already pushed.
- **Git rules:**
  - New commits only. No amend, no force-push, no push.
  - The orchestrator pushes. CI runs are the evidence, so tell me when you need a commit pushed
    to capture CI diagnostics.
  - Never touch the owner's main checkout.
- **Lock:** `export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`, and
  wrap every xcodebuild / hosted / `make build` in `lockf -k "$PLAINSONG_XCODEBUILD_LOCK" …`.
- **Lint:** `PATH=/private/tmp/plainsong-swiftformat-0.62.1:$PATH make lint`. Download nothing.
- **Do not launch or terminate the owner's `app.plainsong.editor`**, and do not run
  `PlainsongUITests`.
- **Recommended model:** Opus. This is timing and root-cause work.

## The failures

Both CI runs on this PR failed in new PR H hosted tests. Both failures start at the **same
wait** in `startHeldBarReplaceAll` (`AppTests/EditorReplaceUIHostedTestSupport.swift`
~133–148):

```
Timed out waiting for the bar's Replace All reaches its held preparation checkpoint
```

That is, after the test clicks the bar's **Replace All** button, preparation never reaches
its first chunk callback (`replaceBatch.onChunkForTesting`) within the 5 s `waitUntil`. Every
assertion after that point is a consequence of this first timeout.

| Run | Head | Test | Follow-on errors |
|---|---|---|---|
| [37580658311](https://github.com/w3d-su/plainsong/actions/runs/37580658311) | `a4cf37b` | `testHostedCancelLeavingWhileFocusedHandsFocusToReplaceAllOrTheField` (listed three times under "Failing tests") | "Timed out waiting for bar control plainsong.editorFind.replaceCancel mounts"; `XCTUnwrap` NSButton at `EditorReplaceUIHostedTestSupport.swift:64` |
| [37745093731](https://github.com/w3d-su/plainsong/actions/runs/37745093731) | `b157e38` | `testHostedExternalReloadKeepsValuesAndExpansionCancelsProgressAndRecountsFirst` (`EditorReplaceUIHostedLifecycleTests.swift` ~117) | `XCTAssertEqual` nil at `:132` |

**Local history:**
- The PR's local runs passed: 352 hosted tests.
- The Cancel hand-off test timed out once locally under heavy load and passed on rerun. That
  was recorded as environmental in `docs/evidence/editor-replace-h-20261006.json`.
- **On CI it fails on every run, in a different test each time. Treat it as a real race.**

**Diagnostics captured at the CI timeout** (run 37745093731):

```
currentMatch={0,3} total=200 queryGeneration=5 focusRequestID=1 focusAppliedID=1 barVisible=true
appNavigation=navigate(id 7, {0,3})  controllerNavigation=navigate(id 7, {0,3})
diskInspectionPending=false reloadPending=false convergencePending=false externalPrompt=nil
replaceAuthorization=allowed
actualKeyWindow=385 replaceKeyWindow=417
window=417 key=true responder=<NSTextView field editor> queryMounted=true queryOwnsResponder=false
appliedSelection={0,3} selectionMatches=true focusReceiptMatches=true
```

So by the time of the timeout:
- Find had settled, with 200 matches.
- Authorization was `allowed`.
- The responder was a field editor: the replacement field, not the query.
- The real `NSApp.keyWindow` (385) **differs from the designated test window** (417).

## Hypotheses (verify; don't assume)

1. **The click lands while Replace All is disabled.**
   - The row's enabled state follows the committed query and validity (`c377da3` changed it so
     buttons don't flap mid-recount).
   - On a slow runner, the Find recount or validation may not have published when the test
     clicks. `performClick` on a disabled `NSButton` is a silent no-op.
   - If the button can *look* enabled to a user while the press is dropped, that is a
     **product bug**. Otherwise the tests must wait for the enabled state.
2. **The bar's own window gate refuses the press.**
   - `isEditorReplaceBarActionAllowed(from:)` (`App/AppState+EditorReplaceUI.swift` ~150) requires
     `window === editorFindKeyWindow()`.
   - The test installs `editorFindHost.keyWindowOverride`
     (`EditorReplaceUIHostedTestSupport.swift` ~22).
   - Check:
     - the override is installed *before* the click;
     - it returns the same `NSWindow` instance as the button's `window`;
     - no other path in the press (for example `EditorFindBarButton`, owned controls, focus
       hand-off) consults `NSApp.keyWindow` or `window.isKeyWindow` directly. On CI that is
       385, not 417. Locally the test window is usually truly key, which would hide this.
   - This gating arrived in `c377da3`, the first CI run after it failed, and earlier commits
     never ran on CI. That timing makes this hypothesis strong.
3. **Preparation starts but is superseded or refused before its first chunk.**
   - Candidates: an authority-generation advance from a late focus report, a recount generation
     bump, or a transient `externalObservationPending` from the fixture's own write or autosave.
   - Check `replaceBatch.lastResult`, `isPreparing`, `replaceStatus` and the authority
     generation at the timeout.
4. **The chunk callback is never reached for this shape.** For example, 200 matches complete in
   one chunk without calling `onChunkForTesting`. Confirm the checkpoint contract: ≤ 64 matches
   or 65,536 units per chunk.

## Method

1. **Instrument the timeout (test-only).** When the "held preparation checkpoint" wait times
   out, print:
   - the Replace All button's `isEnabled`, `isHidden` and `window?.windowNumber`;
   - what `editorFindKeyWindow()` returns;
   - the bar-action-allowed decision and its failing clause. Add a test-visible or DEBUG
     reason; do not change product behaviour.
   - `replaceBatch.isPreparing`, `lastResult` and `replaceStatus`;
   - the authority generation before the click and at the timeout;
   - Find `total` and `queryGeneration`;
   - `replacementValidity`;
   - whether the button action closure ran at all (a DEBUG counter).

   Extend the existing timeout diagnostics (`AppTests/EditorFindHostedTimeoutDiagnostics.swift`),
   or add a sibling.
2. **Reproduce.**
   - Run every test that uses `startHeldBarReplaceAll` or clicks the bar's Replace All, at
     least 30 times with `test-without-building -only-testing:` under the lock.
   - To mimic CI, also run with the test window **not** truly key. For example, make another
     window key after designating the test window, so the override and the real key window
     differ as they did on CI (385 vs 417).
   - If it won't reproduce locally, commit the instrumentation and report. The orchestrator
     pushes it so CI captures the diagnostics; #141 uploads xcresults and logs on failure.
3. **Fix at the root.**
   - **If a product path reads the real key window instead of the seam:** route it through
     `editorFindKeyWindow()`. Production stays `NSApp.keyWindow`.
   - **If a visibly enabled button can drop a press:** make the enabled state and
     `isEditorReplaceBarActionAllowed` agree. A press is accepted exactly when the button is
     enabled; otherwise the button is disabled. Add a test proving that.
   - **If it's test readiness:** before clicking, wait for explicit readiness:
     - the button is enabled;
     - the Find session has settled for the current query generation;
     - no external observation is pending.

     Then assert the click actually started a batch (`isPreparing`, or the action counter), with
     a precise failure message.
   - **Do not just raise timeouts.**
   - Apply the fix to **every** test that uses the shared helper, not only the two that failed.
4. **Hygiene.** Remove or keep the diagnostics deliberately: keep them if they only print on
   timeout.

## Verification

- **Repetition:** 0 failures in 30 or more repeated runs of the Replace-row hosted classes:
  - `EditorReplaceUIHosted*`
  - `EditorReplaceUIHostedFocusHandOffTests`
  - `EditorReplaceUIHostedLifecycleTests`
  - `…IMETests`, `…ControlTests`, `…MenuTests`

  Include the "not truly key" variant. If load is above 20, record it.
- **Hosted, under the lock:**
  - all `EditorFind*` / `EditorReplace*`;
  - F6/F7 (`EditorFindFocusReceiptTests`);
  - `WorkspaceSearch*`;
  - `MenuBarStateTests` / `PlainsongMenuKeyBindingTests`.
- **Other checks:**
  - `make build`;
  - pinned `make lint`;
  - `git diff --check`;
  - files ≤ ~400 lines (`App/AppState+EditorFind.swift` is at about 391; don't grow it).
- **CI:** after the orchestrator pushes, CI must be green on **two consecutive runs**. The
  orchestrator re-runs once.

## Docs

- Update `docs/evidence/editor-replace-h-20261006.json` and the R8 evidence notes. In
  particular, correct the earlier "environmental under load" note for the Cancel hand-off test
  with the confirmed root cause.
- If product behaviour changed (key-window routing, or the enabled/accepted contract), append
  one Decision Log row at the bottom of `docs/decision-log.md`, with no blank lines.

## Final report

- The root cause, with the diagnostic output that proves it, and which hypothesis it confirmed.
- Commits.
- The fix: product or test, and why.
- Repetition results, including the not-truly-key variant.
- Hosted pass counts.
- Anything left open.
