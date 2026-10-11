# Handoff 27d — #151 (Replace PR H): restore the Applying-frame Cancel assertion, and tidy the 27c leftovers

Read `06-phase3-parallel-overview.md` first, **including its update blocks**. Then read
`27c-replace-pr-h-diagnostics-cleanup.md`. Everything there still applies.

The 27c re-review (`549b220..caca3e5`, now pushed) found **NO BLOCKING**:
- the M2 hop-guard tests pass 90/90, and each clause's negative control fails;
- the M3 attribution is confirmed as a fixture artifact, not a race;
- the Release binary has 0 trace strings, and warnings are below the `b157e38` baseline.

This is a small last batch.

## Where you work

- **Worktree:** `/Users/davis._.su/Documents/plainsong-replace-ui`, branch `phase3-editor-replace-ui`.
  - Head `caca3e5`, which equals origin.
  - First run `git fetch origin && git merge --ff-only origin/phase3-editor-replace-ui`. If it is
    not a fast-forward, stop and report.
- **Git:** new commits only. No amend, no force-push, no push. The orchestrator reviews and
  pushes.
- **Never touch** the owner's checkout.
- **Lock:** `export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`. Wrap
  every xcodebuild / hosted / `make build` in `lockf -k "$PLAINSONG_XCODEBUILD_LOCK" …`.
- **Lint:** `PATH=/private/tmp/plainsong-swiftformat-0.62.1:$PATH make lint`. Download nothing.
- **Disk:** about 14 GB free.
  - Prefer the worktree's default DerivedData.
  - Delete any extra copy you make.
  - On "No space left on device", stop and report.
- **Load is often extreme on this Mac** (the 1-min load average has been 150–700).
  - Record the load with every hosted run.
  - Rerun any failure in isolation before attributing it.
- **App:** do not launch or terminate `app.plainsong.editor`, and do not run `PlainsongUITests`.
- **Recommended model:** Sonnet.

## MEDIUM — the Applying-frame "Cancel withdrawn" check no longer tests anything

**Where:** `AppTests/EditorReplaceUIHostedFocusHandOffTests.swift` ~130–163.

**What 27c changed:**
- The test still records `cancelShown` at `willCommitForTesting` (~133).
- But `XCTAssertFalse(cancelShown, "Cancel is withdrawn once preparation is done")` was removed.
  `cancelShown` now appears only in a timeout diagnostic.
- The new stray check (~146) runs after `awaitBarReplaceAll`, when activity is already idle, and
  waits up to 5 s for Cancel to unmount.

**Why it matters:**
- The Decision Log contract says Replace All renders an Applying… frame "(withdrawing Cancel)"
  before the final recheck. Nothing asserts that any more.
- The reviewer proved it in a scratch copy. With the product changed to keep Cancel mounted while
  Applying (`EditorReplaceRow.swift`, `if case .preparing` → `if activity != .idle`):
  - HEAD's test **passed**;
  - the `549b220` test **failed**.

**Fix:**

1. Keep the commit-time observation.
2. If `cancelShown` is true at `willCommit`:
   - record a `REPLSTRAY` entry with `mountedAtCommit=true` in the trace buffer, printed only on
     failure or under `PLAINSONG_HOSTED_TRACE_STDOUT=1`;
   - re-check **after exactly one run-loop turn** (one `DispatchQueue.main.async` hop, not a
     multi-second `waitUntil`).
3. Decide the outcome:
   - If Cancel is still attached after that one turn, **fail hard**.
   - If it was gone after one turn, pass. Record the transient case and the turn count in the
     trace buffer, so the evidence can say how often SwiftUI defers the removal.
4. Negative control: apply the reviewer's product change (keep Cancel mounted while Applying).
   The test must fail. Do not commit that change.
5. Apply the same one-turn rule to the Escape-label path (`EditorReplaceUIHostedLifecycleTests.swift`
   ~44). It currently waits up to 5 s; the 27c handoff asked for one turn.

## Lows (fix in this pass)

1. **The M3 attribution test cannot detect broken forwarding** (`AppTests/EditorFindHostedNavigationRaceTests.swift` ~186).
   - It only asserts that the location contains `(Plainsong/AppState+Workspace.swift:`.
   - Every forwarding step in the refresh chain lives in that same file, so a regression of the
     `fileID`/`line` forwarding would still pass.
   - Fix: assert the hop's **own** call site, for example with an explicit producer tag passed by the
     hop. Do not hard-code a line number that moves with every edit. Show that it fails when
     forwarding is dropped.
2. **The `WorkspaceEventWatcher` doc comment is wrong about `stream`** (`Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceEventWatcher.swift` ~4).
   - It claims `stream` is confined to the queue, but `start()`, `stop()` and `deinit` touch it on
     the caller's thread.
   - This comment justifies `@unchecked Sendable`. State the real rule:
     - `stream` is owned by the caller's thread (main in the app);
     - the handler runs inside the queue's critical section and must never block on main.
3. **Evidence inaccuracies** (`docs/evidence/editor-replace-h-20261006.json`):
   - **"one-run-loop-turn rechecks":** make it true with the Medium fix, or describe what the code
     does.
   - **"strayBranch: 0 branch entries":** `/private/tmp/plainsong-27c-rows-v2-1.log:1346` (if it
     still exists) holds a transient `REPLSTRAY` `progressLabel` entry. Report it.
   - **The commit list** must include `34cecd9`.
   - **The file lengths are stale.**
     - `AppState+Workspace.swift` is 937 lines, not 934.
     - `AppState+ExternalChanges.swift` is 979 lines, not 977.
   - **The row-test count** is 29, not 28.
4. **Long files:** `AppState+Workspace.swift` grew from 895 to 937 lines and
   `AppState+ExternalChanges.swift` from 966 to 979. Both already violated the length limit at
   `b157e38`.
   - Do **not** refactor them here.
   - If a trace helper added in 27b/27c can move to a small `+Tracing` extension file without
     touching behaviour, do it. Otherwise leave them.

## Out of scope: note it for the owner, don't change it

The reviewer noted a pre-existing product behaviour:
- any watcher hop, including an echo of the app's own autosave, starts a disk inspection;
- that advances authority, so it supersedes a preparing Replace All, or refuses one pressed during
  the inspection.

This is the §5.6 fence by design. Add one line to the evidence's open-items list ("possible UX
follow-up: self-write echoes"). Do not change it.

## Verification

- WorkspaceKit `swift test`.
- **Hosted, under the lock:**
  - `EditorReplaceUIHostedFocusHandOffTests` and `EditorReplaceUIHostedLifecycleTests` ×20, plus
    the negative control;
  - the M3 test with its new negative control;
  - all 29 Replace-row tests ×5;
  - `EditorFind*`, `EditorReplace*`, `EditorFindFocusReceiptTests`, `WorkspaceSearch*`,
    `MenuBarStateTests` and `PlainsongMenuKeyBindingTests` once.
- **Builds:** `make build`, and a Release build. The Release binary must still contain 0 trace
  strings.
- **Static checks:**
  - pinned `make lint`;
  - `git diff --check`;
  - warnings no higher than at `caca3e5`;
  - `AppState+EditorFind.swift` ≤ 391 lines.

## Final report

- Commits.
- Each item: what changed, and the named test.
- Negative-control results.
- How often the one-turn recheck found a transient stray, with counts.
- Pass counts and load.
