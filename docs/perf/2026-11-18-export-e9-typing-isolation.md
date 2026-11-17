# Typing while Export as HTML… or Export as PDF… is active (E9)

- Date: 2026-11-18
- Commit: RESULTS PENDING
- Environment: RESULTS PENDING
- Fixture: `Fixtures/large-1mb.md` is both the document typed into and the document
  exported. Budget: `agent.md` §12 typing < 16 ms; gate: `docs/export-gates.md` E9,
  "Export work never enters the editor keystroke path; the existing < 16 ms typing budget
  remains green while export is active."
- Procedure: `PLAINSONG_MAX_LOAD=20 Scripts/run-export-html-e9.sh --typing Release`, then
  the same with `Debug`. Each runs
  `AppBackedEditorPerformanceTests/testTypingStaysIsolatedFromActiveHTMLAndPDFExport`
  with 16 rounds per product.
- Result: RESULTS PENDING

## Why a new probe

The 2026-10-04 E9 record (`docs/perf-log.md`, "Current Export F E9 recorded-load
results") timed one keystroke per `xcodebuild` run, ten runs per arm. Three of ten Debug
keystrokes during an HTML export took over 16 ms, and with one sample per run the
interval on the difference was about 20 ms wide, so the bullet could be neither checked
nor failed. The machine never reaches the idle load that run waited for
(load 6–8 from system daemons alone).

This probe keeps everything in one process and interleaves the two arms, so machine
load reaches both alike, and it takes hundreds of keystrokes per product. It also covers
Export as PDF…, which did not exist when the first probe was written.

## Version 1, superseded before any gate run

The first version (commit `91dbcc8c`) compared all keystrokes of a 30-keystroke burst
without export against all keystrokes during export, classified by whether the export was
still active when each keystroke started. One Release run (load 7–22, product SHA
`91dbcc8c`) and an independent code review showed it could not answer the question:

- Handler time rises over a burst: the first keystrokes after a pause take about 8 ms,
  later ones 12–14 ms, and main-thread CPU rises with them. The export arm's keystrokes
  were mostly the first of a burst, so it looked faster than the baseline
  (HTML −4.2 ms, PDF −1.3 ms median) for that reason alone.
- The export's last synchronous step (fence, write, controller teardown,
  `finishExportHTMLOperation`) ends with the operation already inactive, so a keystroke
  it delayed was classified as after the export and dropped from both arms.
- Main-thread export work that ran between keystrokes appeared in no gated metric.
- Arm order was tied to the offset, and the offsets came from a cold first export.

Its numbers are kept here only as the reason for the redesign: G1 passed for both
products, and G2 failed for PDF because the 30-keystroke baseline itself had p95 20.0 ms
and 27.5% of keystrokes at or over 16 ms at that load.

## Runs of version 2 before idle matching

Three earlier runs of version 2 are not evidence for the gate; each found a defect in the
harness, and none changed a criterion:

- `87b308d2`, Release: the script's own default of 12 rounds overrode the probe's 16,
  leaving HTML's sustained stratum covered by 3 rounds; and the PDF part ended in a
  `CancellationError` partway through its rounds, losing its results. Gate failures are
  now asserted after both products, each product runs in its own `do`/`catch`, and the
  script defaults to 16 rounds (`190e3fbd`).
- `190e3fbd`, Release: HTML passed G0, G1 and G2. The PDF part aborted when one export
  under load (end load 22.5) outlasted the 400-keystroke schedule; the cap is now 1,500.
- `190e3fbd`, Debug, complete: in the PDF export arm, the first keystroke of every burst
  that started 4–11 s after the export command took 15–32 ms (main-thread CPU 15–25 ms),
  against 9–12 ms for bursts that started 0.7 s after it and 6–26 ms for the first
  keystroke of the no-export bursts, which then started 500 ms after the previous arm.
  HTML offsets are all under 1.6 s and showed no such effect. The likeliest cause is the
  idle time before the burst rather than the export, so the no-export burst now waits
  the same offset before it starts. This run's PDF G2 failed on that first-keystroke
  clause (p95 31.7 ms).

## Method (version 2)

Fixture: the app-backed hosted editor of `AppBackedEditorPerformanceTests` (an
`AppState`, its editor binding, and `MarkdownEditorView` in a window), the same harness
as the §12 hosted typing test. Neither the live preview nor the status bar is hosted, in
either arm.

For each product (HTML, then PDF):

1. One cold export that sets nothing.
2. Main-thread windows with no typing, in the order export, idle, idle, export. An export
   window runs one warm export to completion; an idle window lasts as long as the first
   warm export. A run loop observer records every stretch between the main run loop
   waking and sleeping, with its wall and main-thread CPU time. With no typing, the
   export windows' slices are all the main-thread work an export does. The mean of the
   two warm exports is `T`.
3. Sixteen rounds. Each pairs a burst of 30 keystrokes with no export against a burst
   that starts `0.05 T`, `0.3 T`, `0.55 T` or `0.8 T` after the export command
   (rotating by round) and continues until three keystrokes are due after the export
   finished. Both bursts in a round use the same schedule: keystroke `k` is due at
   the offset plus `80 k` ms plus a seeded jitter in `[0, 40)` ms, so keystrokes land at
   different phases of the export's work from round to round. The burst with no export
   also waits the offset first, with the editor idle, so both bursts start after the same
   idle time (see "Runs of version 2 before idle matching" for why). The order of the two bursts
   alternates by round and flips every four rounds, so each offset runs in both orders.
   Bursts and windows are 500 ms apart.
4. The first keystroke during an active export fences it (E1): the operation finishes
   its current step and stops with `.documentChanged`. When the first keystroke ran
   while the export was active, the probe asserts that result and that no file was
   written.

Each keystroke is `insertText("a")` at the top of the document followed by the scheduled
SwiftUI representable update (`measureHostedUpdate`, the §12 hosted measure). The probe
records:

- **handler**: wall time of that insertion and update. This is the existing budget.
- **main-thread CPU**: `CLOCK_THREAD_CPUTIME_ID` over the same interval. Other processes
  inflate wall time but not this.
- **start delay**: how late the keystroke began against its schedule, which is main-actor
  work that held the thread when it was due.
- **event-to-update**: start delay plus handler.
- **untouched**: read inside the timed region, right after the synchronous insertion: the
  export is still the active operation and its task is not cancelled. The read runs in
  both arms so the timed work is the same.

A keystroke counts as during the export when it was due before the export finished
(the instant `didFinishOperation` reported its result). One held up by the export's last
synchronous step therefore counts. Burst position `k` counts from the burst's first
keystroke in both arms. Positions `0–9` are the **burst start** stratum and `10` onward
the **sustained** stratum; arms are only compared within a stratum. Autosave,
statistics and completion tasks are cancelled after each keystroke, outside the timer,
as the §12 hosted test does.

## Criteria (version 2), fixed before its first timed run

Release is the gate configuration (`docs/release-1.0-scope.md`: §12 budgets are re-run on
Release). Debug runs the same probe and is reported, not gated. For each product:

- **G0, isolation and coverage:** no keystroke left the export touched; every fenced
  export ended `.documentChanged` and wrote nothing; at least one round was fenced; at
  least 75% of rounds have a keystroke during the export.
- **G1, no regression:** in each stratum, the pooled median handler time during export
  minus the pooled median without export, with a 95% interval from a cluster bootstrap
  over rounds (10,000 usable resamples, seed 20261118), has an upper end of at most
  +1.0 ms. A stratum with keystrokes during export in fewer than four rounds is not
  covered, and fails.
- **G2, the existing budget:** the first keystroke of each export burst that fell during
  the export (one keystroke after a pause, which is what the §12 hosted test times) has
  handler p95 under 16 ms; and in each stratum the share of keystrokes at or over 16 ms
  during export is at most the share without export plus one percentage point. The
  second clause lets load push both arms over the budget alike without letting the
  export arm do it more often.

Reported, not gated: start delay, event-to-update and main-thread CPU for both arms, and
the busy slices of the export and idle windows. A smoke run of this version, before the
criteria were final, already showed export-window slices of 52 ms (HTML) and 94 ms
(PDF) in Debug against at most 7 ms in idle windows. Those chunks are not in the
keystroke handler, but a keystroke that arrives during one waits for it. The existing E9
rule names only the writer, with "hundreds of milliseconds" as the trigger for an owner
decision about moving work off the main thread. This record lists every export slice of
16 ms or more and leaves the decision on them to the owner rather than setting a
threshold after seeing data.

## Results

RESULTS PENDING
