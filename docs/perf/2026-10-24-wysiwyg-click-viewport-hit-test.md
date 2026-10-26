# WYSIWYG pointer click on large-1mb.md: viewport hit-test against whole-document layout

- Date: 2026-10-24
- Commit: B is `phase3-wysiwyg-click-layout` at `07e961d697918033f54c502418426269bda75b18`
  (viewport hit-test `5fd870e` plus the wrapped-line fix); A is main
  `1428bf1c6e57aea1a435a4f55c658088e29d391c` with the same probe test files copied in
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Swift 6.4, STTextView 2.4.1,
  Apple M1 Pro 8 cores 16 GiB on battery power; SwiftPM release build
  (`-c release -Xswiftc -enable-testing`); 1-minute load 14.4–56.0 across the series (other
  sessions were building), recorded per run below, no idle-machine gate
- Fixture: `Fixtures/large-1mb.md` (1,048,962 UTF-16 units), 900 × 800 pt window, line
  height multiple 1.25, the viewport ±4 Ki folded with `.inlineFoldRevealWithLinkFolding`,
  thumbnail placeholders on the viewport's images; agent.md §12 typing latency (< 16 ms)
- Procedure: `PLAINSONG_RUN_WYSIWYG_CLICK_PROBE=1 PLAINSONG_WYSIWYG_CLICK_PROBE_ROUNDS=3
  swift test -c release -Xswiftc -enable-testing --skip-build --filter
  WYSIWYGPointerClickCostProbeTests` in `Packages/EditorKit`, 12 processes in the order
  ABBA ABBA ABBA. Each round opens a fresh editor per position (top, middle, end; order
  reversed on odd rounds), scrolls there, and dispatches real left-mouse-down `NSEvent`s
  at 24 visible characters: folded bold, link text, a heading, the line of an image
  thumbnail, a task item, then the middle of each visible line. One keystroke follows the
  first click. Clicks are timed around `mouseDown(with:)`; the keystroke covers
  `insertText` + layout + display.
- Result: median of the 6 run medians per side, A → B. No absolute click budget exists;
  the keystroke after a click is within the §12 16 ms budget for B at every position and
  over it for A at top and middle.

| Position | First click | Later clicks (median) | Later clicks (p95) | Keystroke after click |
|---|---:|---:|---:|---:|
| top | 1,320.4 → 0.082 ms | 89.50 → 0.056 ms | 121.5 → 0.106 ms | 166.9 → 2.38 ms |
| middle | 1,243.0 → 0.140 ms | 107.3 → 0.089 ms | 174.1 → 0.179 ms | 98.8 → 5.55 ms |
| end | 1,151.5 → 0.124 ms | 123.6 → 0.089 ms | 175.3 → 0.166 ms | 12.2 → 9.17 ms |

In every A/B pair B's later-click median is at least 1,144× lower and its first click at
least 5,913× lower. A's first click lays out the whole document; its later clicks still
enumerate every fragment (90–125 ms). A's keystroke after a click is slow above the end
because laying out the whole document recreated every cached paragraph element below the
caret, which each edit then rewrites (the cost `EditorTextElementCacheTrimmer` exists to
remove). At the end there is nothing below the caret, so A and B type alike there. B's
single worst click in 1,296 was 19.9 ms (run 11 at the end, load 26.4); its p95 never
exceeded 0.231 ms.

Placement: every one of B's 1,296 clicks landed in the clicked source line. That check
compared the caret with the whole source line (paragraph), so a caret on another visual
line of the same wrapped paragraph would also have passed; the 2026-10-26 re-run below
checks the clicked character. A missed 24 per run, the same 8 targets in each round: link
text and the thumbnail line at every position (the wrapped-line offset error), plus folded
bold in the middle and at the end (whole-document layout replaced the estimated heights
above the viewport and moved the clicked text).

Raw runs (top / middle / end: first click / later-click median / p95 / keystroke, ms):

| Run | Side | Load before → after | top | middle | end |
|---:|:---:|---|---|---|---|
| 1 | A | 49.3 → 36.1 | 1196.70 / 83.08 / 90.16 / 155.66 | 1125.72 / 99.98 / 117.54 / 86.59 | 1080.78 / 117.19 / 161.79 / 11.72 |
| 2 | B | 36.1 → 46.1 | 0.09 / 0.062 / 0.229 / 2.50 | 0.14 / 0.087 / 0.148 / 5.46 | 0.18 / 0.082 / 0.113 / 9.20 |
| 3 | B | 46.1 → 44.8 | 0.07 / 0.052 / 0.077 / 2.34 | 0.13 / 0.088 / 0.164 / 5.37 | 0.12 / 0.094 / 0.156 / 8.80 |
| 4 | A | 44.8 → 32.6 | 1379.40 / 91.88 / 144.74 / 171.31 | 1257.48 / 113.27 / 207.95 / 97.89 | 1193.18 / 124.06 / 173.60 / 11.85 |
| 5 | A | 32.6 → 19.7 | 1294.23 / 87.12 / 102.34 / 161.60 | 1203.57 / 107.68 / 140.30 / 90.98 | 1141.75 / 125.33 / 176.91 / 12.01 |
| 6 | B | 19.7 → 18.7 | 0.08 / 0.056 / 0.112 / 2.19 | 0.15 / 0.093 / 0.181 / 5.83 | 0.13 / 0.089 / 0.160 / 9.18 |
| 7 | B | 18.7 → 17.5 | 0.08 / 0.056 / 0.103 / 2.35 | 0.15 / 0.089 / 0.186 / 5.72 | 0.16 / 0.090 / 0.193 / 9.07 |
| 8 | A | 17.5 → 14.4 | 1346.59 / 101.50 / 498.95 / 174.83 | 1400.71 / 106.88 / 274.20 / 110.34 | 1161.26 / 123.24 / 197.53 / 12.43 |
| 9 | A | 14.4 → 25.6 | 1288.21 / 86.88 / 122.79 / 162.54 | 1228.47 / 106.55 / 137.47 / 103.93 | 1129.35 / 120.93 / 159.28 / 13.13 |
| 10 | B | 25.6 → 26.4 | 0.08 / 0.059 / 0.097 / 3.95 | 0.13 / 0.090 / 0.202 / 5.64 | 0.11 / 0.087 / 0.172 / 9.16 |
| 11 | B | 26.4 → 24.8 | 0.08 / 0.054 / 0.110 / 2.42 | 0.14 / 0.090 / 0.178 / 5.24 | 0.12 / 0.101 / 0.231 / 10.40 |
| 12 | A | 24.8 → 56.0 | 1461.29 / 92.16 / 120.13 / 179.21 | 1424.39 / 116.03 / 344.37 / 99.80 | 1291.75 / 131.27 / 357.39 / 13.24 |

The caret snap and image-reveal lookups a click runs after the hit-test (fold and image
attribute runs) took 0.003–0.036 ms on both sides, so they were left unchanged.

Document-length scaling, the always-on gate: `WYSIWYGPointerHitTestTests.
testClickWorkDoesNotGrowWithTheDocument` clicks folded bold in the middle of a 1,500- and
a 60,000-line document. In a release run both visited 32 layout fragments and clicked in
0.09 and 0.08 ms, and paragraphs at 10, 25, 75, 90 and 99.9% of the document stayed without
layout. As a negative control, re-inserting main's
whole-document `ensureLayout` in front of the new hit-test failed it: 43.3 ms and
1,685.9 ms clicks, all five probe paragraphs laid out, and carets on the wrong line in
both documents.

## Review-fix re-run (2026-10-26)

- Commit: B′ is the review-fix commit on `phase3-wysiwyg-click-layout` (parent `1d6a22d`):
  the viewport walk enumerates without `.ensuresLayout` and stops before a fragment without
  layout, and a stale viewport lays out a band around the point instead of running the
  view's layout. T is the parent `1d6a22d` with the same probe file, its stale check read
  through `coversPoint`.
- Environment: as above (battery power, release build); 1-minute load 9.3–20.2, recorded
  per run below.
- Procedure: the same command with `PLAINSONG_WYSIWYG_CLICK_PROBE_ROUNDS=3`, 3 processes in
  the order B′ T B′. The probe changed in two ways. A caret now counts as placed only at
  either edge of the clicked character's composed sequence, not anywhere in its source line.
  Each position also gets one click after scrolling a screen and a half (down, or up at the
  end) without a layout pass, at the middle of the visible area. That stale click passes
  when, after the next layout pass, the laid-out viewport maps the same window point to the
  same caret.
- Result: regular clicks are unchanged; every click of every run, stale ones included,
  landed on target. A stale click costs 1.3–15 ms on B′, against 12–40 ms on T, whose
  click ran the view's whole layout pass.

| Run | Side | Load before → after | top | middle | end |
|---:|:---:|---|---|---|---|
| 1 | B′ | 9.64 → 9.32 | 0.048 / 0.071 / 1.34 (1.75) | 0.070 / 0.131 / 6.24 (7.56) | 0.075 / 0.176 / 14.98 (15.64) |
| 2 | T | 14.10 → 20.21 | 0.049 / 0.078 / 12.21 (13.88) | 0.108 / 0.439 / 40.42 (49.14) | 0.078 / 0.114 / 31.34 (32.48) |
| 3 | B′ | 17.80 → 16.74 | 0.049 / 0.166 / 1.50 (1.74) | 0.073 / 0.178 / 6.90 (8.11) | 0.070 / 0.142 / 13.04 (24.33) |

Cells: later-click median / p95 / stale-click median (max), ms. First clicks were
0.066–0.183 ms and the keystroke after a click 2.18–8.92 ms on both sides.

Placement: 216 regular clicks per run, each at the clicked character, and 9 stale clicks
per run, each where the laid-out viewport maps the point. T's stale clicks also landed,
because the probe leaves no post-layout action pending; the two ways T misplaces a stale
click are covered by `WYSIWYGPointerHitTestTests` instead. A variant of B′ whose band was
laid out from its own top missed all 12 of its stale clicks over two runs (load 49.8–74.6),
by 44–120 characters. TextKit's height estimate for the never-laid-out text between the
band and the next viewport's top edge put the band's lines a line or two from where the
next layout pass drew them, so B′ lays out from that edge.

The stale click's cost grows with the text above the point. TextKit's lookups by position
(`ensureLayout(for: CGRect)`, `textLayoutFragment(for: CGPoint)`) scan the fragment frames
above it, but lay out and create only the band's paragraphs. The viewport walk, still the
path for every click on a laid-out viewport, does not grow: in the debug suite
`testClickWorkDoesNotGrowWithTheDocument` visits 32 fragments at both 1,500 and 60,000
lines. Its former wall-clock assertion is now a printed diagnostic: 0.09–0.15 ms for each
document in this session's debug runs.
