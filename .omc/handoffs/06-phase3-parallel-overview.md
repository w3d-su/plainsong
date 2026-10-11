# Handoff 6 — Phase 3 parallel work while `phase3-latex-math` is in progress

> **Update 2026-09-29 — read this first; it overrides §0, §2, and the Decision Log note below.**
> - The LaTeX work has landed on `main` (#125 math preview, #126 Insert Inline/Display Math).
>   The §2 "files the LaTeX branch is changing" avoid-list is obsolete. The owner's main
>   checkout may again hold uncommitted work, so the rule "never touch
>   `/Users/davis._.su/Documents/blogeditor`; always use your own worktree" still applies.
> - #127 moved the Decision Log out of `agent.md` into **`docs/decision-log.md`**. Append
>   one row at the **bottom of that file**. Do not add rows to `agent.md`.
> - Bridge `PROTOCOL_VERSION` is **8** once #121 merges. It is 7 until then.
> - Status of handoffs 07–10:
>   - 07 → #120, 08 → #121, 09 → #123: review-fixed, merged main, and awaiting the owner's merge.
>   - 10 → #124: merged.
>   - 11 still needs the owner.
> - Next streams: **12** (Export PR F) and **13** (Replace PR E). Start them only after their
>   prerequisite PRs are on `main` (see each handoff).
> - 2026-09-30:
>   - 13 → #131.
>   - 12 Phase A hit the D5 design stop. D5 is amended in #130; **14** (Export PR E2) is stacked
>     on #130, and PR F Phase B waits for E2.
>   - **15** (Replace PR F, WYSIWYG single Replace) is stacked on #131.
>   - Replace PR G (Replace All) follows 15. Do not run G and 15 in parallel; they share the
>     WYSIWYG suspend/reapply surface.
> - **2026-10-07 — newest status.**
>   - `main` is `9282881`: #145 Replace All, #148 WorkspaceKit R15 and #149 hard-link alias
>     message are merged.
>   - Open PRs:
>     - #150: Keep Mine presentation (26A). CI green, mergeable. Known follow-up recorded in
>       `docs/perf-log.md`: `MarkdownTextView.applyIncomingTextIfNeeded` (clean external
>       reload / App text replacement) has the same same-length image-marker gap. It needs
>       its own small PR.
>     - #151: Replace PR H (27). Review fixes landed; R8 stays open on the owner FKA smoke.
>     - #147: Export PR G (PDF/Print). Review BLOCKING (4). The owner chose **A1**
>       (variable-height PDF pages, splitting at child/line boundaries) and **B1** (Print
>       prints the captured light-theme PDF via PDFKit). Fix per **handoff 20a**.
>     - #143: vitest bump, mergeable.
>   - Ready: **20a** (Opus).
>   - Next after #151: Replace PR I (owner IME, R9, R10) and Windows PR B1 (AppState-wide;
>     wait for #151).
>   - The pinned SwiftFormat 0.62.1 copy is at `/private/tmp/plainsong-swiftformat-0.62.1/`.
> - **2026-10-06.**
>   - `origin/main` = `8eb18b9`. Merged since 10-04: #135, #136, #137, #138, #139, #140, #141,
>     #142, #144, #146.
>   - Open:
>     - #145 Replace All (another agent is merging main);
>     - #143 Dependabot vitest 4→5 (dev-only, CI green).
>   - **Ready-to-run handoffs:**
>
>     | Handoff | Topic | When |
>     |---|---|---|
>     | 20 | Export PDF/Print | now; #138 is merged |
>     | 26 | three small PRs: Keep Mine presentation, WorkspaceKit R15 budgets, hard-link alias message | now |
>     | 27 | Replace PR H, product UI | after #145 merges |
>
>   - **Failure A is root-caused.** Workspace-search cancels superseded Find navigation; #146 fixed it.
> - **2026-10-04 — read this first; it overrides older notes.**
>   - `origin/main` = `069ee44`. Merged: #133 (Save mode mask) and #134 (`EditorFindController`
>     split).
>   - Open PRs:
>     - #135 controller lifetime test;
>     - #136 highlight scheduler fix;
>     - #137 Replace PR F (stacked on #136);
>     - #138 Export PR F (HTML);
>     - #139 window-state spec;
>     - #140 F2 pre-go cleanup.
>   - **Shared xcodebuild lock for every agent:**
>     `export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`.
>     Wrap every xcodebuild / hosted test / `make build` / `make test` in `lockf -k "$PLAINSONG_XCODEBUILD_LOCK" …`.
>     Never commit a session-scratchpad path.
>   - **Pinned SwiftFormat 0.62.1.** Reuse an existing verified copy if one is present, or download
>     and verify it per the note above, with owner approval. Put it first on `PATH` for `make lint`.
>   - **Ready-to-run handoffs:**
>
>     | Handoff | Topic | When |
>     |---|---|---|
>     | 22 | paired A/B measurements on a quiet machine (no other builds; load ≤ 6) for #136, #137, #138 | now; true idle (load < 3) is unreachable on this M1 Pro |
>     | 23 | CI failure evidence + PerformanceTests preflight | now |
>     | 19 | Replace All | after #136 and #137 merge |
>     | 20 | Export PDF/Print | after #138 merges |
>     | 21 | reconciled-source presentation fix | after #136 and #137 merge |
>
>   - The 2026-10-02 CI audit is at
>     `~/.codex/visualizations/2026/10/02/01a0fb51-b4e6-79a3-9408-0e11ce578f8e/ci-audit/CI-AUDIT.md`.
>   - Known open CI flakes:
>     - F2 pre-go cleanup (#140 addresses it);
>     - PerformanceBudgetTests resource reads (handoff 23).
>
>     If a PR goes red only on one of these and does not touch that area, rerun the job before
>     debugging the PR.
>   - **#137 is red intermittently** ("Timed out waiting for Find applies the current match").
>     #136 had one `refused(externalObservationPending)` failure. Triage is **handoff 24**. Do not
>     merge #137 until failure A is explained.
>   - 22 and 23 are done: measurements are recorded on #136, #137 and #138, and #141 is the CI
>     evidence PR.
> - 2026-10-01:
>   - #130, #131 and #132 (E2) are merged; `origin/main` = `e95ac36`.
>   - 12 (Export PR F Phase B) and 17 (Save mode mask) are running.
>   - 18 (window-state spec, docs only) is running.
>   - A highlight-scheduler bug-fix branch, `phase3-editor-highlight-schedule-fix`, is in flight;
>     Replace PR F (15) will stack on it.
>   - **16** (split `EditorFindController.swift`) branches from `main`. It can run in parallel
>     with 15, but must land before Replace PR G.
> - SwiftFormat 0.62.1 (CI pin): if you have no verified copy, download
>   `https://github.com/nicklockwood/SwiftFormat/releases/download/0.62.1/swiftformat.zip`,
>   verify it against the SHA-256 in `.github/workflows/ci.yml`, and put it first on `PATH`
>   for `make lint`. Only download it when the owner has approved this in the session.

Snapshot: 2026-09-28. `origin/main` = `6108c64` (#109 F9, on top of #112 R0 and #119 protocol v7).
Read this file first, then the stream handoff you were given (07–13).

## 0. The one rule that overrides everything

The owner's main checkout `/Users/davis._.su/Documents/blogeditor` is on `phase3-latex-math`
with a **large, uncommitted working tree** (~12k new lines of math work plus an `agent.md` /
Decision Log restructure). It is still being developed.

In that checkout, **never** run `git checkout`, `switch`, `stash`, `reset`, `clean`, `commit`,
`rebase`, `make format`, `make generate`, `make preview-bundle`, or `npm ci`, and never edit a
file there. Those commands rewrite or discard the owner's unsaved work. Read these handoff files
by absolute path only.

Every stream works in its **own worktree branched from `origin/main`**:

```sh
cd /Users/davis._.su/Documents/blogeditor
git fetch origin
git worktree add ../plainsong-<slug> -b phase3-<slug> origin/main
cd ../plainsong-<slug>
make generate                     # the .xcodeproj is generated per worktree
(cd preview-src && npm ci)        # only if the stream touches preview-src
```

Branch from `origin/main`, not local `main`, because local `main` is stale (`789cd50`).

## 1. Streams that can run at the same time

| # | Handoff | Branch | Layers | Owner needed? | Conflict risk with LaTeX |
|---|---|---|---|---|---|
| 07 | Replace PR D: source-only single Replace | `phase3-editor-replace-single` | EditorKit, thin App publication hook, AppTests | No | **Medium**: EditorKit coordinator neighbourhood |
| 08 | Export PR D: assets + offline fidelity | `phase3-export-assets` | PreviewKit, preview-src, bundle | D3 already signed off | **Medium**: preview-src bundle regeneration |
| 09 | Export PR E: one-shot artifact writer | `phase3-export-oneshot-writer` | WorkspaceKit (+ plain App adapter only if needed) | No | **None** |
| 10 | Editor Find F4b + F7 hosted gates | `phase3-editor-find-hosted-gates` | AppTests only (test-only) | No (F6 IME and FKA smoke are owner items) | **Low** |
| 11 | Workspace Search DoD close-out | `phase3-workspace-search-dod-closeout` | docs only, after an owner run | **Yes**: interactive `make test` + a maintainer decision | Low (Decision Log row) |

Not parallelizable yet (listed so nobody starts them early):

- Replace PR E–I: each depends on PR D (07), and H (UI) needs D, E, and G.
- Export PR F (File → Export as HTML…) needs D (08) and E (09). PR G (PDF/Print) needs F.
- F6 real-IME smoke, F2 evidence artifacts, WYSIWYG D.4 promotion, and P1/P2 signing are owner items.
- Math WebKit acceptance and math perf belong to the LaTeX line. Do not touch them here.

## 2. Files the LaTeX branch is actively changing

Avoid editing these in any parallel PR. If a change is truly unavoidable, keep the diff
minimal, add new code in a **new extension file** instead of the shared file, and call it out in
the PR body under "LaTeX overlap".

- `App/PlainsongCommands.swift` (the Format menu gains math items)
- `Packages/EditorKit/Sources/EditorKit/`: `EditingBehaviorsSupport.swift`, `MarkdownSTTextView.swift`,
  `MarkdownTextView.swift`, `MarkdownTextView+Dismantle.swift`, `MarkdownTextViewCoordinator.swift`
  (especially its stored-property block around line 290 and its text-change delegate paths),
  `MarkdownTextViewCoordinator+Bridges.swift`, `MarkdownTextViewCoordinator+Input.swift`
- `Packages/MarkdownCore/Sources/MarkdownCore/`: `FormattingEditing.swift`, `MarkdownEditTypes.swift`.
  `EditingBehaviorProposal.textMutation` is gaining a `restoresSelectionOnRedo:` parameter, so do
  not change or add cases to that enum.
- `preview-src/src/pipeline.ts`, `preview-src/src/styles/base.css`, `preview-src/test/__snapshots__/pipeline.test.ts.snap`
- `App/Resources/preview/bundle.js` / `bundle.css`: generated files. Never hand-merge them. The
  PR that merges second runs `make preview-bundle` again after merging `origin/main`.
- `agent.md`: §2, §3, §4, §6.2, §6.4, §12, §13, §14, §17, and §18 are being rewritten. `README.md`
  and `docs/perf-log.md` should only get appends at the end.
- Reserved new names: `MathEditing*`, `MathZone*`, `MathLineContainers`, `JSLexicalState*`,
  `EditorMathCommandEligibility`, `EditingBehaviorsSupport+Math`, `preview-src/src/math.ts`,
  `Fixtures/math*.md`.

### Decision Log location

On `origin/main`, the Decision Log is still the table in `agent.md` §18. The LaTeX branch is
moving it to `docs/decision-log.md`, but that move is uncommitted. Parallel PRs should:

- append **one self-contained row per PR at the end of the `agent.md` §18 table** (the same
  mechanics as #112–#119);
- **not** create `docs/decision-log.md`;
- not edit any other `agent.md` section unless the stream handoff says to. If a behaviour
  change truly needs a § edit, make it the smallest possible diff and flag it under "LaTeX
  overlap".

The LaTeX owner will move rows that merge first into the new file when rebasing.

## 3. Overlaps between the parallel streams

| Pair | Overlap | Rule |
|---|---|---|
| 07 ↔ 10 | Both are near Editor Find. 07 edits `EditorFindController.swift` and `App/AppState+EditorFindLifecycle.swift`; 10 adds hosted tests. | 10 is **test-only**. It does not modify Find production files. If 10 finds a production defect, it stops and reports it instead of fixing it. Shared test support (`AppTests/EditorFindHostedGateTestSupport.swift`) may only receive additive helpers. |
| 08 ↔ 09 | None. 08 is PreviewKit/preview-src; 09 is WorkspaceKit. | No PreviewKit → WorkspaceKit edge (export-gates §4). |
| 08 ↔ LaTeX | Both regenerate the bundle. Export must embed KaTeX CSS/fonts, and LaTeX adds the `div.plainsong-math-block` wrapper and math CSS. | 08 embeds whatever CSS the bundle ships (generic, no math-specific code). After LaTeX lands, 08 (or PR G) adds `Fixtures/math.md` to the export matrix. |
| 11 ↔ everyone | Appends to the Decision Log and edits `docs/acceptance-matrix.md` / `docs/risk-register.md`. | Trivial append conflicts; resolve by keeping both rows. |

## 4. Machine contention (one Mac, many worktrees)

- `swift test --package-path Packages/<Kit>` in different worktrees can run concurrently: each
  worktree has its own `.build`, so the only cost is CPU. Use package slices for the development loop.
- **Serialize** `PerformanceTests`, `PlainsongUITests`, and any wall-clock gate. Never run them
  while another worktree is running `make test`, `make lint`, or `make format`. WS4B budgets show
  roughly 14x slowdowns under contention; rerun the isolated `-only-testing` probe before
  believing a budget failure.
- XCUITests (`PlainsongUITests`) need a logged-in interactive GUI session with the app able to
  become frontmost. From a non-interactive agent they fail with `Running Background` or
  `Authentication canceled`. That is environmental. Prove it (rerun with only your change
  reverted) before calling it pre-existing in a PR body.

## 5. Common definition of done (every stream)

- `make format` **inside your worktree only**.
- Lint the way CI does: SwiftFormat **0.62.1** is pinned in `.github/workflows/ci.yml` with a
  SHA-256, and local Homebrew is 0.61.1. Download the 0.62.1 release zip, verify it against the
  SHA in `ci.yml`, unzip it into a scratch directory, then run `PATH=<dir>:$PATH make lint`.
  Findings on untouched files from a different local version are not your regression.
- `make test` (or the package slices + the named hosted tests, plus a stated reason for anything
  you could not run), `make build`, and `git diff --check`.
- If `preview-src` changed: `cd preview-src && npm run typecheck && npm test`, then
  `make preview-bundle`, and commit the regenerated `App/Resources/preview/` output in the same commit.
- Bridge change: mirror `BridgeMessage.swift` / `ExportBridgeMessages.swift` ↔ `bridge.ts`, bump
  `PROTOCOL_VERSION` (currently **7**), and rebuild the bundle, all in one commit (`agent.md` §17.5).
- A gate box is checked only with a **named test** or an owner-recorded result in the same commit.
  Never check a box because the surrounding text sounds done.
- Files ≤ ~400 lines, no new Swift/npm dependency, and no `.xcodeproj` edits (edit `project.yml` +
  `make generate` only if target membership must change).
- PR against `main`. Commit subject starts with `Phase 3:`. The PR body lists exactly which gate
  bullets close and which stay open. Push only your branch. **Never merge, force-push, or push to `main`.**
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. PR body ends with
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
