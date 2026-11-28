# Typing while an export is active (E9), re-run on `main` after #279

- Date: 2026-11-28
- Commit: `main` at `15ec386f`. The probe, its summary code, the script and
  `docs/evidence/export-e9-typing-analysis.py` are unchanged since the 2026-11-18
  replication at `446a9e80` (they landed in #275). The product code now includes #279
  (one-pass native source copy) and the Swift 6 language-mode moves (#304–#309).
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro (MacBookPro18,3),
  screen unlocked, testable Release (`-O`, `ENABLE_TESTABILITY=YES`). One-minute load per
  round: HTML 13.9–20.9, PDF 8.3–46.7. An unrelated WebKit WebContent process held about
  one core at the start and the end of the run.
- Fixture: `Fixtures/large-1mb.md`, typed into and exported. Budget: `agent.md` §12
  typing < 16 ms; gate: `docs/export-gates.md` E9, "Export work never enters the editor
  keystroke path; the existing < 16 ms typing budget remains green while export is
  active."
- Procedure: `PLAINSONG_MAX_LOAD=20 Scripts/run-export-html-e9.sh --typing Release`
  (run `Release-typing-20261128-022550-34587`, 16 rounds per product), then
  `python3 -I docs/evidence/export-e9-typing-analysis.py <run.log>`.
- Result: the 2026-11-18 verdicts again. HTML passes G0, G1 and G2. PDF passes G0 and G1
  and fails G2's first-keystroke clause (max 30.9 ms). The burst with no export, after
  the same idle time, fails that measure the same way. The owner accepted both open
  decisions on 2026-11-28 (`docs/decisions/2026-11-28-export-e9-typing-owner-acceptance.md`),
  and E9's typing bullet is checked.

Method and criteria are those of `docs/perf/2026-11-18-export-e9-typing-isolation.md`,
unchanged. Handler times are in ms; "share" is the share of keystrokes at or over 16 ms;
intervals are the 95% cluster bootstrap on the pooled median difference, during export
minus without.

## Results

| | HTML | PDF |
|---|---|---|
| Warm export `T` | 1,993 ms | 33,007 ms |
| Rounds with keystrokes during export / fenced / fence failures / untouched violations | 16 / 16 / 0 / 0 | 14 / 14 / 0 / 0 |
| Burst start, without export: median, p95, share | 11.12, 18.53, 16.2% | 13.31, 25.28, 35.0% |
| Burst start, during export: median, p95, share | 6.68, 11.86, 3.7% | 11.83, 25.71, 22.9% |
| Burst start difference | −4.44 [−5.45, −3.33] | −1.49 [−4.52, +0.15] |
| Sustained, without export: median, p95, share | 11.16, 19.19, 19.1% | 13.04, 21.96, 27.8% |
| Sustained, during export: median, p95, share (rounds) | 6.53, 14.26, 5.0% (5) | 10.10, 20.01, 19.1% (10) |
| Sustained difference | −4.63 [−6.00, −3.55] | −2.94 [−4.92, −1.42] |
| First keystroke during export: median, p95, share | 5.86, 9.27, 0.0% | 20.92, 30.87, 71.4% |
| Same round, same position pairs: median [interval] (pairs) | −3.82 [−4.79, −2.19] (128) | −2.43 [−4.62, −0.95] (318) |
| G0 / G1 / G2 | PASS / PASS / PASS | PASS / PASS / FAIL |

PDF's `T` is 70% longer than on 2026-11-18 (19,396 ms) because load reached 46.7 while it
was measured. Two PDF rounds at the last offset (`0.8 T`, 26.4 s) started their burst
after that round's export had already finished (22.1 and 24.4 s), so 14 of 16 rounds
have keystrokes during the export; G0 needs 12. In PDF round 1 the first keystroke fenced
the export 9.9 s in, but the export ran until 70.0 s: a fenced export finishes its
current step, here the capture, before it stops (E1). It wrote nothing.

Typing during an export is again not slower. The burst-start PDF interval reaches
+0.15 ms, inside G1's +1.0 ms limit.

## The first keystroke after an idle pause (no export)

The no-export burst's first keystroke against its keystrokes 1–9, by the idle time
before the burst (offset plus the 500 ms pause), medians of four rounds, with the
2026-11-18 Release run (before #279) beside it. The idle times differ because they
follow each run's `T`.

| Product | This run: idle, first / 1–9 | 2026-11-18: idle, first / 1–9 |
|---|---|---|
| HTML | 0.60 s: 8.9 / 9.2 | 0.59 s: 12.0 / 10.0 |
| HTML | 1.10 s: 12.6 / 9.9 | 1.05 s: 24.8 / 14.5 |
| HTML | 1.60 s: 14.3 / 11.7 | 1.51 s: 23.8 / 14.0 |
| HTML | 2.10 s: 17.5 / 12.0 | 1.98 s: 22.3 / 13.2 |
| PDF | 2.15 s: 21.4 / 12.8 | 1.47 s: 22.1 / 14.0 |
| PDF | 10.40 s: 28.3 / 13.2 | 6.32 s: 24.2 / 13.7 |
| PDF | 18.65 s: 21.4 / 11.4 | 11.17 s: 27.7 / 13.7 |
| PDF | 26.91 s: 26.1 / 16.2 | 16.02 s: 24.8 / 13.7 |

Up to 1.6 s of idle, the first keystroke is now within 3 ms of the next ones; on
2026-11-18, after 1.05 and 1.51 s, it was about 10 ms slower. That fits #279, which
removed one of the two passes over the document per keystroke, the work in which the
first keystroke after a pause lost its extra cycles to cold caches. From about 2 s
on it is still 5–15 ms slower than keystrokes 1–9 and over 16 ms in every row. PDF's
first keystroke during the export comes after 2–27 s without input, so it falls in this
range. Why the longer pauses still cost this much is not established; this run does not
measure clock state or cache misses. It is a §12 typing issue with or without an export,
and the §12 hosted test, which types after a 100 ms settle, does not see it.

## Export main-thread work (reported)

Busy slices of the main run loop with no typing, in the two warm-export windows and the
two idle windows of each product, as wall/CPU ms at ms after the export command:

| | Export windows: max; slices ≥16 / ≥50 / ≥100 ms | Longest export slices | Idle windows: max |
|---|---|---|---|
| HTML | 58.5; 3 / 1 / 0 | 58.5/55.5 @1081, 48.2/32.1 @0, 36.9/26.5 @0 | 0.4 |
| PDF | 222.4; 21 / 5 / 3 | 222.4/73.4 @0, 216.5/4.9 @532, 112.5/33.9 @0, 62.6/29.6 @9964, 52.4/46.8 @1154 | 3.7 |

The three PDF slices over 100 ms of wall time had 73.4, 4.9 and 33.9 ms of main-thread
CPU; load stretched them. The most CPU in one slice is 73.4 ms, at the command (67.4 ms
on 2026-11-18, about 1 s in). HTML's slice about 1 s in, 55.5 ms CPU, matches the
render request that carries the 1 MiB source to WebKit, as before; step names are still
inferred from timing.

A keystroke due during one of these waits for it. The largest start delays of a
keystroke during an export were 62.1 ms (HTML, 1.4 s after the command) and 182.7 ms
(PDF round 1, due 69.8 s after the command, just before the fenced export ended at
70.0 s, with load rising to 46.7). That PDF keystroke was due while the export was active
and began after it had ended, so the export's last synchronous step held it; its CPU time
is not recorded. Without an export the largest start delays were 18.6 ms (HTML) and
30.5 ms (PDF). Event-to-update during export reached 67.3 ms (HTML) and 188.0 ms (PDF).

## Verdict

By the criteria fixed on 2026-11-18, PDF's G2 fails again, for the same reason. The owner
decided on 2026-11-28:

1. The no-export control answers PDF's first-keystroke clause: after the same idle time
   the first keystroke costs the same with no export.
2. The export's main-thread chunks are acceptable as they are: up to 73 ms of CPU in one
   Release slice, below the E9 rule's owner trigger of hundreds of milliseconds, and only
   while a user-started export runs.

E9's typing bullet is checked on G0, G1, HTML's G2 and these two decisions. The first
keystroke after an idle pause of about 2 s or more stays open as a §12 item of its own.

The raw run log is not committed. Every number above comes from its `E9 TYPING`
summary lines and `E9 TYPING JSON` lines, through the probe's printed summary and
`docs/evidence/export-e9-typing-analysis.py`.
