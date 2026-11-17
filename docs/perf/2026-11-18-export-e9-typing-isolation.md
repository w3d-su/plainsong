# Typing while Export as HTML… or Export as PDF… is active (E9)

- Date: 2026-11-18
- Commit: RESULTS PENDING
- Environment: RESULTS PENDING
- Fixture: `Fixtures/large-1mb.md` is both the document typed into and the document
  exported. Budget: `agent.md` §12 typing < 16 ms; gate: `docs/export-gates.md` E9,
  "Export work never enters the editor keystroke path; the existing < 16 ms typing budget
  remains green while export is active."
- Procedure: `PLAINSONG_MAX_LOAD=12 Scripts/run-export-html-e9.sh --typing Release`, then
  the same with `Debug`. Each runs
  `AppBackedEditorPerformanceTests/testTypingStaysIsolatedFromActiveHTMLAndPDFExport`
  with 12 rounds per product.
- Result: RESULTS PENDING

## Why a new probe

The 2026-10-04 E9 record (`docs/perf-log.md`, "Current Export F E9 recorded-load
results") timed one keystroke per `xcodebuild` run, ten runs per arm. Three of ten Debug
keystrokes during an HTML export took over 16 ms, and with one sample per run the
interval on the difference was about 20 ms wide, so the bullet could be neither checked
nor failed. The machine never reaches the idle load that run waited for
(load 6–8 from system daemons alone).

This probe keeps everything in one process and interleaves the two arms, so machine
load reaches both alike, and it takes hundreds of keystrokes per arm. It also covers
Export as PDF…, which did not exist when the first probe was written.

## Method

Fixture: the app-backed hosted editor of `AppBackedEditorPerformanceTests` (an
`AppState`, its editor binding, and `MarkdownEditorView` in a window), the same harness
as the §12 hosted typing test. Neither the live preview nor the status bar is hosted, in
either arm.

For each product (HTML, then PDF):

1. One export with no typing. It warms WebKit, must finish `.exported`, and its wall
   time `T` sets the offsets below.
2. Twelve rounds. Each round has an arm without export (30 keystrokes, 80 ms apart) and
   an arm with export: the product command starts, the first keystroke lands at
   0.05 `T`, 0.25 `T`, 0.45 `T` or 0.65 `T` (rotating by round), and keystrokes follow
   every 80 ms until three after the operation finishes. Even rounds run the arm without
   export first, odd rounds the export arm first. Arms are 500 ms apart.
3. The first keystroke fences the export (E1). The operation keeps running until its
   current step ends, then stops with `.documentChanged`; the probe asserts that result
   and that no file was written. Typing continues through that stop and the offscreen
   controller's teardown.

Each keystroke is `insertText("a")` at the top of the document followed by the scheduled
SwiftUI representable update (`measureHostedUpdate`, the §12 hosted measure). The probe
records:

- **handler**: wall time of that insertion and update. This is the existing budget.
- **main-thread CPU**: `CLOCK_THREAD_CPUTIME_ID` over the same interval. Other processes
  inflate wall time but not this; export work that runs on the main thread inside the
  interval still counts.
- **start delay**: how late the keystroke began against its schedule. Main-actor export
  work that runs between keystrokes shows up here and nowhere else.
- **untouched**: read inside the timed region, right after the synchronous insertion: the
  export is still the active operation and its task is not cancelled. The read runs in
  both arms so the timed work is the same.

A keystroke counts as "during export" when the export was still the active operation at
the moment it started. Autosave, statistics and completion tasks are cancelled after each
keystroke, outside the timer, as the §12 hosted test does.

## Criteria, fixed before the first timed run

Release is the gate configuration (`docs/release-1.0-scope.md`: §12 budgets are re-run on
Release). Debug runs the same probe and is reported, not gated. For each product:

- **G0, isolation (functional):** every keystroke made while an export was active left
  the export untouched; every fenced export ended `.documentChanged` and wrote nothing;
  at least one keystroke landed during an active export. Asserted in both configurations.
- **G1, no regression:** pooled median handler time during export minus pooled median
  without export. A cluster bootstrap resamples whole rounds (10,000 resamples, seed
  20261118). The upper end of its 95% interval must be at most +1.0 ms.
- **G2, the existing budget:** handler p95 during export is under 16 ms, and the share of
  keystrokes at or over 16 ms during export is at most the share without export plus one
  percentage point. The second clause lets load push both arms over the budget alike
  without letting the export arm do it more often.

Start delay and main-thread CPU are reported for every product and configuration but do
not gate. A start delay of hundreds of milliseconds during export would meet the
writer-off-main decision trigger in `docs/export-gates.md` E9 and is reported as such.

## Results

RESULTS PENDING
