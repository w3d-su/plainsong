# Handoff 27c — #151 (Replace PR H): test the watcher hop guard, trim the diagnostics, finish the row-flake traces

Read `06-phase3-parallel-overview.md` first, **including its update blocks**. Then read `27b-replace-pr-h-ci-flakes.md`. Everything there still applies.

The 27b re-review (`b157e38..549b220`, now pushed) found **NO BLOCKING**.

## Where you work

- **Worktree:** `/Users/davis._.su/Documents/plainsong-replace-ui`
- **Branch:** `phase3-editor-replace-ui`, head `549b220`. This equals origin.
- **Before you start:** run `git fetch origin && git merge --ff-only origin/phase3-editor-replace-ui`. If the merge is not a fast-forward, stop and report.
- **Git:** new commits only. No amend, no force-push, no push. The orchestrator reviews and pushes.
- **Never touch** the owner's checkout.
- **Lock:** `export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`, then wrap every xcodebuild / hosted / `make build` in `lockf -k "$PLAINSONG_XCODEBUILD_LOCK" …`.
- **Lint:** `PATH=/private/tmp/plainsong-swiftformat-0.62.1:$PATH make lint`. Download nothing.
- **Disk is nearly full.**
  - Use one DerivedData folder under `/private/tmp`, and delete it at the end.
  - On "No space left on device", stop and report.
  - Never delete anything you did not create.
- **App:** do not launch or terminate `app.plainsong.editor`, and do not run `PlainsongUITests`.
- **Recommended model:** Opus. This needs timing judgment.

## What the re-review established

**Mechanism.** The decisive mechanism is the **App main-actor hop**, not a debounce firing after `stop()`.

The implementer's trace (`/private/tmp/plainsong-27b-repro/f2b-18.log`, if it still exists) shows this order:

1. The watcher handler fired **before** `stop()`, while the test setup was still running synchronously.
2. Its `Task { @MainActor }` hop was already queued ahead of the Replace All task.
3. `stop()` cannot recall a hop that is already queued.
4. Only the new App guard closes that path: `watcher === workspaceWatcher && !watcher.isStopped`, at `App/AppState+Workspace.swift` ~358–366.

**WorkspaceKit.** The queue-confinement changes close real races, but those races are theoretical. The new `WorkspaceEventWatcherTests` are deterministic, and they fail on the old watcher.

**Hypothesis 2 (key-window gate).** It is ruled out by the trace and by a code audit. `PLAINSONG_HOSTED_FOREIGN_KEY_WINDOW=1` does **nothing** locally: the test host is never active, so `NSApp.keyWindow` stays nil, and every diagnostic shows `actualKeyWindow=nil`. So the evidence's "×30 foreign" run never reproduced CI's 385 vs 417 split.

**CI.** The push of `549b220` is collecting evidence now. Check its result (see below) before you finish.

## Fix these

### M1 — trace entries print entire prepared batches

**Where:**
- `App/AppState+EditorReplaceBatch.swift` ~56, ~123 (`prepared=\(prepared)`) and ~134 (`result=\(result)`);
- `AppTests/EditorFindHostedTimeoutDiagnostics.swift` ~23 (`lastResult=`).

**Problem.** On the 8,921-match fixture, one trace entry is 8,078,547 characters.
- It is built on the main actor between preparation and the Applying frame, which leaves a 141 ms gap there.
- Each failure prints it twice, about 16 MB of a 20 MB log.

This alone can cause the Applying-frame flake it is meant to diagnose.

**Fix:**
- Log the case name plus `changedCount` / `totalCount`, and the generation if useful. Never log source strings or range arrays.
- Add a guard test that asserts the trace entry length stays bounded, for example under 512 characters, on a large plan.

### M2 — the decisive App hop guard has no deterministic test

**Problem.** Removing `!watcher.isStopped` fails no test today.

**Fix:** add a hosted test that does the following:

1. Open the workspace.
2. Call `simulateDeliveredEventForTesting()` (via `@testable import WorkspaceKit`).
3. Block the main actor longer than the 300 ms debounce, so the handler fires and its hop queues.
4. Call `workspaceWatcher?.stop()`, then yield.
5. Assert:
   - no disk inspection or `handleExternalChange`;
   - no authority-generation advance;
   - no `externalObservationPending`.

**Variant:** a hop from a *replaced* watcher (`watcher !== workspaceWatcher`) is dropped too.

**Negative control:** remove each clause in turn. The test must fail. Do not commit that change.

### M3 — the producer of an external change cannot be attributed

**Problem.** `b5571d7` removed the producer tracing. The remaining `handleExternalChange` trace line cannot say which of its 12 callers ran, and three of them pass `advancing=true`. The reviewer saw an unattributed `handleExternalChange file=post.md advancing=true` 40 ms before the press, in a *passing* run.

**Fix:**
- Add `fileID: String = #fileID, line: Int = #line` defaults to that DEBUG trace, so every call site is named.
- Add a one-line DEBUG trace in the watcher hop recording accepted or dropped, and why: stopped, or replaced.
- Investigate that `advancing=true` call 40 ms before the press. Find which caller it is, and whether it can refuse or supersede a Replace All on CI. If it can, that is a real remaining race: fix it or report it with evidence.

## Lows (fix in this pass)

1. **Five new compiler warnings.**
   - **Where:**
     - `WorkspaceEventWatcher.swift` ~116, ~135. The package builds with StrictConcurrency and had 0 warnings at base.
     - `AppState+Workspace.swift` ~362–363: sending `watcherBox` / a non-Sendable capture.
     - `EditorFindBarButton.swift` ~134: `?? "?"` on a non-optional.
   - **Fix:**
     - Mark the watcher and the box `@unchecked Sendable`, with a comment stating the queue confinement.
     - Drop the redundant `??`.
   - **Target:** no new warnings versus `b157e38`.
2. **DEBUG stdout on passing tests.**
   - **What prints:**
     - `REPLTRACE` label make/update/dismantle prints: 1,201 lines per 280 tests;
     - the `replaceBarTrace@checkpoint` dump (`EditorReplaceUIHostedTestSupport.swift` ~204), which prints on every pass of `testHostedFileSwitch…`.
   - **Fix:** keep both in the in-memory trace buffer and print only on failure. Alternatively, gate them behind an environment variable that CI sets. Either way, Debug app consoles must stay quiet.
3. **Work that still runs in Release, and trace-buffer skew.**
   - **Wrap these in `#if DEBUG`:**
     - `EditorFindBarButton.swift` ~121, `label.stringValue != text`;
     - `EditorReplaceRow.swift` ~32, `activity == .applying || status != nil`. This one runs on every bar body evaluation.
   - **Trace buffer:**
     - In DEBUG, trace `rowModel` only on a change, not on every publish while a status is visible. Today it floods the 64-entry buffer.
     - Log each authority advance once, not twice (`AppState+EditorReplaceAuthority.swift` ~99 and `EditorFindHost.swift` ~112).
4. **The Applying-frame flake's diagnostics miss the actual failing control.**
   - The failing assertion is about the **Cancel button**, which has no mount/dismantle trace and no ancestry dump. Add both, in the same style as the label.
   - In both row-flake failure paths (Escape label and Applying Cancel), re-check after one run-loop turn and print whether the stray view is still attached. That separates SwiftUI's deferred removal (transient, cosmetic) from a persistent mount.
   - The reviewer considers both cosmetic. A lingering Cancel is inert because `cancelEditorReplaceAllFromBar` guards on `isPreparing`.
   - If the re-check shows the removal is always transient, wait for it in the tests. Do not raise timeouts, and do not change product code.
5. **Make the foreign-key-window variant real, or remove the claim.**
   - It needs the host app active, with a second window truly key. One option is `NSApp.activate(ignoringOtherApps:)` plus `makeKeyAndOrderFront` on a foreign window.
   - Do it only if this works in the hosted runner without stealing the owner's focus, and without affecting the owner's running Plainsong. Otherwise, correct the evidence text.
   - Related: `hasKeyWindowFindChromeFocus()` (`App/AppState+EditorFindChromeFocus.swift` ~19–20) reads `keyWindowNumberOverride ?? NSApp.keyWindow` and ignores `keyWindowOverride`. It is harmless today, but route it through the same seam for consistency.
6. **Lint:** `AppState+EditorReplaceUI.swift` ~93 is 122 characters. Wrap it.

## Docs

- **Mechanism wording.** Correct the commit-history-facing wording in the Decision Log row and in `docs/evidence/editor-replace-h-20261006.json`:
  - the decisive fix is the App hop guard;
  - the WorkspaceKit confinement closes theoretical races.
  - Edit the existing 2026-10-09 row in place, with no new row and no blank lines.
- **Evidence.** Record:
  - the foreign-variant limitation (or the fixed variant);
  - the re-review's suite result at lower load: `EditorFind*` / `EditorReplace*` / `WorkspaceSearch*` / menu tests 353 pass, 0 fail.
  - Drop "470/64 WebKit-under-load" as the headline. Keep it as a run under disk and load pressure.
- **CI.**
  1. Read the CI result for `549b220`:
     ```sh
     gh pr checks 151 --repo w3d-su/plainsong
     ```
     If it failed, also run `gh run view <id> --repo w3d-su/plainsong --log-failed`. Do not rerun CI yourself.
  2. Record whether any held-checkpoint timeout or `externalObservationPending` refusal appeared.
  3. If a Replace-row test failed, root-cause it from the new diagnostics before finishing.

## Verification

- **Packages:** WorkspaceKit `swift test` (all), plus `WorkspaceEventWatcherTests` ×30.
- **Hosted, under the lock:**
  - the new M2 test ×30, plus its negative controls;
  - the 28 Replace-row tests ×10;
  - `EditorFind*`, `EditorReplace*`, `EditorFindFocusReceiptTests`, `WorkspaceSearch*`, `MenuBarStateTests` and `PlainsongMenuKeyBindingTests`, once.
  - If load is above 20, rerun failures in isolation.
- **Builds:** `make build`, plus a Release build to prove the traces compile out (0 trace strings in the binary).
- **Checks:**
  - pinned `make lint`;
  - `git diff --check`;
  - warnings no higher than at `b157e38`;
  - files ≤ ~400 lines (`AppState+EditorFind.swift` stays ≤ 391).
- **Cleanup:** delete your DerivedData at the end.

## Final report

- Commits.
- Each item: what changed, and the named test.
- Negative-control results.
- The CI result for `549b220`, and what it showed.
- The attribution of the 40 ms `advancing=true` call.
- Repetition counts and load.
- What is left.
