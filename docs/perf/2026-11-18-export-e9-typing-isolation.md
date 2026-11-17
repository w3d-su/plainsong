# Typing while Export as HTML… or Export as PDF… is active (E9)

- Date: 2026-11-18
- Commit: `6e4c0fd1` (probe and harness only; product code is `main` at `f664c5af`).
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro (MacBookPro18,3),
  screen unlocked. Release is the script's testable Release (`-O` with
  `ENABLE_TESTABILITY=YES`). One-minute load per round: Release 5.95–28.31, Debug
  3.35–21.39. An unrelated WebKit WebContent process held about one core at the start of
  both runs and at the end of the Release run.
- Fixture: `Fixtures/large-1mb.md` is both the document typed into and the document
  exported. Budget: `agent.md` §12 typing < 16 ms; gate: `docs/export-gates.md` E9,
  "Export work never enters the editor keystroke path; the existing < 16 ms typing budget
  remains green while export is active."
- Procedure: `PLAINSONG_MAX_LOAD=20 Scripts/run-export-html-e9.sh --typing Release`, then
  the same with `Debug`. Each runs
  `AppBackedEditorPerformanceTests/testTypingStaysIsolatedFromActiveHTMLAndPDFExport`
  with 16 rounds per product.
- Result: Release HTML passes G0, G1 and G2. Release PDF passes G0 and G1 and fails G2's
  first-keystroke clause (p95 31.8 ms). The burst with no export, after the same idle
  time, fails that measure the same way (first keystroke median 22–28 ms), so the
  failure comes from the idle pause, not the export. A Release replication with a
  corrected busy-slice monitor gives the same verdicts. E9's typing bullet stays
  unchecked; see "Verdict".

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
  against 9–12 ms for bursts that started 0.7 s after it and 9–26 ms for the first
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
   export windows' slices are the export's main-thread work. These runs used one observer
   at order 0, so work that later-ordered observers do before the thread sleeps (Core
   Animation commit, AppKit display) is outside the slices, and the slice figures are
   lower bounds. The monitor now ends a slice after every other observer has run (see
   "Busy-slice monitor" below). The mean of the two warm exports is `T`.
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
the **sustained** stratum; arms are only compared within a stratum. Within a stratum the
samples are pooled, not matched position by position: a no-export burst stops at position
29, while a PDF export burst can run to position 200 or more. Autosave,
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
  export arm do it more often. As the code is written, a stratum that is not covered
  fails G2 too. With 16 rounds, the nearest-rank p95 of the first keystrokes is their
  maximum, so all of them must be under 16 ms.

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

Runs `Release-typing-20261118-023321-8281` and `Debug-typing-20261118-024422-12008`, both
at `6e4c0fd1`, 16 rounds per product. Handler times are in ms. "Share" is the share of
keystrokes at or over 16 ms. Intervals are the 95% cluster bootstrap on the pooled median
difference, during export minus without.

### Release (gate)

| | HTML | PDF |
|---|---|---|
| Warm export `T` | 1,845 ms | 19,396 ms |
| Rounds with keystrokes during export / fenced / fence failures / untouched violations | 16 / 16 / 0 / 0 | 16 / 16 / 0 / 0 |
| Burst start, without export: median, p95, share | 13.79, 25.72, 35.0% | 15.05, 25.92, 47.5% |
| Burst start, during export: median, p95, share | 8.19, 13.91, 1.0% | 11.65, 25.00, 23.7% |
| Burst start difference | −5.60 [−6.62, −4.04] | −3.40 [−7.14, −1.18] |
| Sustained, without export: median, p95, share | 12.79, 22.70, 31.9% | 14.02, 23.98, 40.6% |
| Sustained, during export: median, p95, share (rounds) | 7.84, 15.23, 0.0% (4) | 11.44, 20.83, 23.6% (11) |
| Sustained difference | −4.95 [−5.65, −4.11] | −2.58 [−4.25, −1.21] |
| First keystroke during export: median, p95, share | 8.28, 14.32, 0.0% | 19.52, 31.79, 50.0% |
| G0 / G1 / G2 | PASS / PASS / PASS | PASS / PASS / FAIL |

### Debug (reported)

| | HTML | PDF |
|---|---|---|
| Warm export `T` | 1,717 ms | 17,744 ms |
| Rounds with keystrokes during export / fenced / fence failures / untouched violations | 16 / 16 / 0 / 0 | 16 / 16 / 0 / 0 |
| Burst start, without → during: median (share) | 8.75 (13.1%) → 8.45 (3.5%) | 12.64 (31.9%) → 12.13 (24.8%) |
| Burst start difference | −0.30 [−1.37, +0.16] | −0.50 [−1.76, +0.88] |
| Sustained, without → during: median (share), rounds | 8.70 (7.5%) → 8.41 (6.5%), 6 | 10.97 (25.0%) → 8.38 (13.5%), 12 |
| Sustained difference | −0.30 [−0.88, +0.26] | −2.58 [−3.71, −1.55] |
| First keystroke during export: median, p95, share | 8.34, 10.08, 0.0% | 24.55, 42.54, 68.8% |
| G0 / G1 / G2 | PASS / PASS / PASS | PASS / PASS / FAIL |

### Same round, same burst position (reported, not gated)

The gated comparisons pool each stratum, so they mix burst position with the export: in
the burst-start stratum handler time still rises with position and the export arm's
keystrokes sit mostly at its early positions, and in PDF's sustained stratum the export
arm runs far past the no-export burst's last position, 29.
`docs/evidence/export-e9-typing-analysis.py` pairs every keystroke during the export with
the no-export keystroke at the same position in the same round (positions 0–29; later PDF
keystrokes have no partner):

| Run | Pairs | Median difference [95% cluster interval] | Unpaired later keystrokes |
|---|---:|---|---:|
| Release HTML | 116 | −4.49 [−6.83, −2.60] | 0 |
| Release PDF | 357 | −1.62 [−2.61, −0.89] | 985 |
| Debug HTML | 144 | −0.79 [−1.77, +0.04] | 0 |
| Debug PDF | 377 | −0.34 [−0.90, −0.12] | 724 |

Typing during an export is not slower in any run. Release keystrokes during an export are
faster than without one, by more than the pairing explains. Why is not established;
main-thread CPU time drops with wall time (Release HTML median 12.36 → 7.69 ms), which
fits the export keeping the CPU at a higher performance state rather than less work being
done.

### The first keystroke after an idle pause (no export)

The same analysis compares the no-export burst's first keystroke with its keystrokes 1–9,
by the idle time before the burst (offset plus the 500 ms pause). Each value is the median
of four rounds:

| Idle before the burst | Release first / 1–9 | Debug first / 1–9 |
|---|---|---|
| HTML 0.59 s | 12.0 / 10.0 | 10.7 / 7.4 |
| HTML 1.05 s | 24.8 / 14.5 | 22.7 / 9.5 |
| HTML 1.51 s | 23.8 / 14.0 | 26.7 / 8.5 |
| HTML 1.98 s | 22.3 / 13.2 | 20.5 / 8.7 |
| PDF 1.47 s | 22.1 / 14.0 | 29.2 / 10.5 |
| PDF 6.32 s | 24.2 / 13.7 | 22.9 / 11.7 |
| PDF 11.17 s | 27.7 / 13.7 | 27.8 / 11.4 |
| PDF 16.02 s | 24.8 / 13.7 | 32.8 / 12.7 |

(The Debug idle times are 0.59, 1.02, 1.44, 1.87 s for HTML and 1.39, 5.82, 10.26,
14.70 s for PDF.)

With no export, the first keystroke after about one second or more of idle has a median
of 20–33 ms, 8–20 ms more than keystrokes 1–9 of the same burst, and main-thread CPU
rises with it. After 0.6 s the gap is 2–3 ms. The §12 hosted typing test types after a 100 ms settle and cannot see this.

In the export arm the editor has had no input for just as long, yet the first keystroke
is fast at every HTML offset (5.7–14.3 ms in Release, up to 2.0 s after the last
keystroke) and at PDF's first offset, while the export's start-up and render work keep the
main thread busy (the four HTML export windows have 83–249 run loop wake-ups a second, an
idle window about 10). It is slow at PDF's later offsets, in the capture step, where the
main thread does little (a whole PDF export window averages 41–46 wake-ups a second).
That argues against editor work scheduled after an input pause and for a CPU
performance state that drops when the main thread is lightly loaded; it is not verified. Either way, PDF's G2 failure is this
effect: the no-export bursts after the same idle time fail the same clause.

### Export main-thread work between keystrokes (reported)

Busy slices of the main run loop in the two warm-export windows and the two idle windows
of each product, with no typing. Slices are wall/CPU ms at their start, ms after the
export command:

| Run | Export windows: max; slices ≥16 / ≥50 / ≥100 ms | Longest export slices | Idle windows: max |
|---|---|---|---|
| Release HTML | 62.5; 4 / 2 / 0 | 62.5/31.3 @0, 51.4/50.6 @1059, 42.4/28.1 @0 | 0.5 |
| Release PDF | 84.9; 13 / 3 / 0 | 84.9/36.0 @0, 52.6/51.9 @1211, 50.1/31.3 @0 | 4.1 |
| Debug HTML | 66.6; 4 / 2 / 0 | 66.6/66.2 @987, 59.0/58.3 @1016, 44.7/28.5 @0 | 0.2 |
| Debug PDF | 94.9; 11 / 6 / 0 | 94.9/94.0 @2902, 92.7/92.2 @2588, 89.4/38.9 @0 | 1.5 |

The export does its main-thread work in a few chunks. One comes at the command: 42–89 ms
wall with 28–39 ms CPU in every window. A CPU-bound one comes 1.0–1.2 s in, which matches
the render request that carries the 1 MiB source to WebKit: 59–70 ms in every Debug
window; in Release 51–52 ms in one window per product and split into slices of 15–20 ms
in the other. For PDF a series of smaller capture slices follows. Debug PDF's two chunks
of about 93 ms CPU at 2.6–2.9 s are under 28 ms in Release. None reaches 100 ms, but
every figure here is a lower bound (see Method). The step names are inferred from
timing, not instrumented. A keystroke due during a chunk waits for it: the largest start delay of
a keystroke during export was 19.0 ms (Release HTML) and 40.2 ms (Release PDF), against
14.2 and 11.8 ms without export.

## Verdict

- **Keystroke path (G0):** no keystroke made during an export changed the export's
  operation or task, and all 64 fenced exports stopped with `.documentChanged` and wrote
  nothing. The edit path has no reference to export code; the export finds the edit only
  through its own fences (`App/AppState+ExportHTML.swift`).
- **No regression (G1):** passes for both products in both configurations. Within each
  stratum, and in the same-round, same-position pairs, typing during an export is not
  slower.
- **Budget (G2):** passes for HTML. PDF fails the first-keystroke clause in both
  configurations. The control shows the cause is the idle pause before the keystroke,
  which costs the same with no export, and the share clause, which compares the arms
  within each stratum, passes.

By the criteria fixed before this run, E9's typing bullet is not met, and it stays
unchecked. Two owner decisions would close it:

1. Whether the first-keystroke clause is answered by the no-export control, or the
   first-keystroke-after-idle cost has to be found and fixed first (it is a §12 typing
   issue on its own, with or without export) and this probe re-run.
2. Whether the export's main-thread chunks are acceptable, or should move off the main
   thread. With the corrected monitor (below), Release has up to 67 ms of CPU in one
   slice about 1 s into the export. At the command the Release runs show 41–85 ms wall
   with 28–37 ms CPU. No Release slice reaches 100 ms; a Debug PDF slice reached 112 ms. The existing E9 rule names only
   the writer, at hundreds of milliseconds.

## Busy-slice monitor and Release replication

The runs above used one run loop observer at order 0 for both the wake and the sleep
callback, as `MainRunLoopBusyMonitor` in the PlainsongTests target still does. The sleep
callback at order 0 runs before observers with a later order, such as Core Animation's
commit, so their work before the thread sleeps fell outside every slice. Since this
record, `ExportTypingBusyMonitor` uses two observers: the wake callback at the lowest
order and the sleep callback at the highest, so a slice spans everything the run loop
does between waking and sleeping. A Debug smoke run with it found slices up to 112 ms
(106 ms CPU) in a PDF export window, against 94.9 ms with the old monitor.

A full Release run at `446a9e80` with the corrected monitor
(`Release-typing-20261118-031106-23640`, load 3.31–12.17) replicates every verdict.
It is a replication; the gate result above is the run at `6e4c0fd1`.

| | HTML | PDF |
|---|---|---|
| G0 / G1 / G2 | PASS / PASS / PASS | PASS / PASS / FAIL |
| Burst start difference | −4.59 [−6.20, −3.39] | −1.64 [−4.12, −0.14] |
| Sustained difference (rounds) | −4.83 [−5.46, −3.88] (4) | −3.12 [−4.45, −2.26] (12) |
| First keystroke during export: median, max | 8.31, 14.11 | 19.23, 28.88 |
| Same-position pairs: median [interval] | −4.08 [−6.24, −3.08] | −1.31 [−2.22, −0.52] |
| No-export first keystroke after ≥ 1 s idle (medians of 4 rounds) | 20.7–26.2 | 21.9–27.7 |
| Largest start delay during export / without | 13.7 / 13.2 | 15.5 / 13.5 |

Busy slices with the corrected monitor, Release, wall/CPU ms at ms after the command:

| | Export windows: max; slices ≥16 / ≥50 / ≥100 | At the command | About 1 s in | Idle windows: max |
|---|---|---|---|---|
| HTML | 66.2; 5 / 2 / 0 | 48.5/33.4, 53.4/36.8 | 66.2/65.9 @995; 48.9/48.7 @1065 | 0.5 |
| PDF | 67.6; 39 / 3 / 0 | 52.2/35.7, 40.9/28.3 | 67.6/67.4 @983; 60.2/59.9 @1016 | 1.1 |

The 1 s chunk is now one slice of 49–67 ms CPU in every window (HTML's second window
also has a 16 ms slice just before it). PDF has 39 slices of
16 ms or more against 13 with the old monitor, because the capture step's commit work is
now counted.

Raw run logs are not committed; the three full runs above are kept locally with their
load snapshots, and every table here is recomputed from their `E9 TYPING JSON` lines by
the probe's printed summary or `docs/evidence/export-e9-typing-analysis.py`.
