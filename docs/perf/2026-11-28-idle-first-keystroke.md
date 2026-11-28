# The first keystroke after an idle pause of 2 s or more

- Date: 2026-11-28
- Commit: `main` at `15ec386f`, plus this PR's probe changes (test code only). The
  editor's product code is unchanged.
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro
  (MacBookPro18,3; 6 performance and 2 efficiency cores, 16 GB), screen unlocked,
  testable Release (`-O`, `ENABLE_TESTABILITY=YES`). The one-minute load of each run is
  in the run list below. The hosted test app is never the active app
  (`NSApp.isActive == false`); its main thread runs at user-interactive QoS (33).
- Fixture: `Fixtures/large-1mb.md` (1,048,962 bytes, ASCII). Budget: `agent.md` §12,
  typing < 16 ms.
- Procedure: `AppBackedEditorPerformanceTests/testFirstKeystrokeAfterAnIdlePause` with
  `TEST_RUNNER_PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE=1`, built with `xcodebuild -scheme
  PerformanceTests -configuration Release ENABLE_TESTABILITY=YES build-for-testing` and
  run with `test-without-building`. Options are listed under "The probe".
- Result: outcome (b). The cost is not Plainsong's. A keystroke retires the same
  ~48 M main-thread instructions at every position, after any idle. Two system
  policies set the rest:
  1. The scheduler. The same keystroke takes 5.2 ms on a performance core and 15.7 ms
     on an efficiency core. Which core the main thread gets changes with load and with
     its position in a burst. Under load like that of the E9 runs (run A below), the
     main thread ran on efficiency cores for 93–98% of keystrokes.
  2. The memory compressor. Under memory pressure the kernel compresses 5–33 MiB of
     the idle process's heap, mostly after 5–20 s. The first keystroke afterwards
     decompresses 3–16 MiB of it: 900–1,600 page faults and 2.6–15 ms of kernel time.
     The pages hold small AppKit, Core Foundation and SwiftUI heap blocks, not the
     document's buffers. Keeping those pages referenced during the idle removes the
     extra cost, so the compressor causes it. Doing that in the product is not a fix
     (see "What Plainsong controls").

  At 2 s on an efficiency core the first keystroke retires the same instructions in
  about 25% more cycles: cold caches, with no compression yet. On a performance core
  there is no measurable cost.

## The probe

The probe from `docs/perf/2026-11-18-keystroke-native-copy.md` now waits 0.1, 1, 2, 5,
10 and 20 s (`…_IDLES_MS`), then types `…_KEYSTROKES` (default 10) keystrokes 80 ms
apart. For each keystroke it records:

- the hosted §12 measure ("handler") and the main thread's CPU time;
- from `thread_selfcounts` kind 4 (`THSC_TIME_CPI_PER_PERF_LEVEL`), the main thread's
  instructions, cycles, user time and system time on each core type. The field order
  was checked with a compute loop and a syscall loop; counts include kernel mode;
- the process's page faults (`TASK_EVENTS_INFO`), in total and inside `insertText`;
- the process's resident, anonymous, compressed and reusable memory and malloc totals
  (`TASK_VM_INFO`, `malloc_zone_statistics`) before the idle and around the keystroke;
- the first keystroke's compressed and resident pages per VM region tag
  (`mach_vm_region_recurse`, which touches no page).

Opt-in diagnostics:

- `…_ARMS` interleaves the arms below with the idles in a seeded order. `none` only
  waits. The touch arms read one part of the keystroke's memory after the idle, before
  the first keystroke: `storage` (every UTF-16 unit of the text storage),
  `attributes` (every attribute run), `native` (every byte of the published source),
  `malloc` (allocations the size of the native copy's scratch and result) and `copy`
  (one native copy). `keepWarm` reads one byte of each resident page of the heap
  regions every 500 ms during the idle. `regionWalk` makes the same region walk and
  `mincore` queries without reading the pages; it is the control for the walk's own
  CPU and cache effects.
- `…_HEAP=1` records which malloc pages were compressed before the first keystroke
  (`mincore`) and which of them it decompressed. After the trial it walks the malloc
  zones' in-use blocks with the zones locked and names the blocks on those pages by
  their Objective-C or Swift class.

## Runs

| Run | Time | Load (1 min) | Content |
|---|---|---|---|
| A, loaded sweep | 14:03–14:07 | 7.4–25.8 | 6 idles × 6 repetitions × 10 keystrokes |
| B, memory | 14:09–14:12 | 9.1–18.4 | 5 idles × 4 × 5 |
| C, touch arms | 14:14–14:19 | 5.7–23.6 | 12 s × 6 arms × 4 × 3 |
| D, region census | 14:21–14:25 | 4.5–8.1 | 12 and 20 s × 5 × 2 |
| E, heap blocks | 14:27–14:30 | 5.1–9.7 | 12 and 20 s × 5 × 2 |
| F, keep-warm | 14:33–14:40 | 5.1–10.7 | 2, 10 and 20 s × 3 arms × 4 × 5 |
| G, light sweep | 14:40–14:45 | 3.7–7.0 (22.1 at the end) | as A |
| H, keep-warm | 14:46–14:56 | 7.9–22.2 | 10 and 20 s × 3 arms × 6 × 5 |

From 13:50 to 14:20 another session ran a Debug build of Plainsong and then 20 or more
HTML and PDF exports on this Mac. Runs A–C fall in that window. Their timings show the
loaded case, the one the E9 runs saw. Their fault and memory counts do not depend on
timing, but the extra memory pressure may have raised them. D–H ran after that window.
Runs A–G used the probe before its final clean-up (arm names, file layout), with the
same measurement code; run H used the committed probe.

## By idle time, loaded and light

Medians of six trials for the first keystroke, and of 54 for keystrokes 1–9. "On E" is
the share of keystrokes with more than half of their cycles on efficiency cores.
Instructions are main-thread instructions, including kernel mode.

| Idle | Run | Handler ms, first / 1–9 | Instructions M, first / 1–9 | System ms, first | Faults, first | On E, first / 1–9 |
|---|---|---|---|---|---|---|
| 0.1 s | A | 15.42 / 14.79 | 48.65 / 48.70 | 0.92 | 5 | 4 of 6 / 98% |
| 1 s | A | 13.51 / 15.76 | 48.43 / 47.92 | 0.75 | 10 | 4 of 6 / 96% |
| 2 s | A | 20.36 / 14.27 | 49.22 / 47.91 | 1.56 | 24 | 6 of 6 / 93% |
| 5 s | A | 22.57 / 14.78 | 54.86 / 48.28 | 4.18 | 700 | 5 of 6 / 94% |
| 10 s | A | 25.99 / 14.83 | 59.56 / 47.79 | 6.10 | 1,311 | 5 of 6 / 98% |
| 20 s | A | 22.65 / 15.11 | 59.86 / 47.73 | 7.42 | 1,290 | 3 of 6 / 98% |
| 0.1 s | G | 5.29 / 12.72 | 48.44 / 48.37 | 0.12 | 11 | 0 of 6 / 72% |
| 1 s | G | 5.44 / 11.77 | 48.28 / 48.45 | 0.22 | 13 | 0 of 6 / 72% |
| 2 s | G | 5.49 / 12.85 | 48.03 / 47.88 | 0.28 | 50 | 0 of 6 / 74% |
| 5 s | G | 6.13 / 10.75 | 49.29 / 47.56 | 0.37 | 88 | 0 of 6 / 65% |
| 10 s | G | 5.51 / 12.24 | 47.38 / 47.94 | 0.36 | 140 | 0 of 6 / 70% |
| 20 s | G | 7.60 / 13.68 | 53.84 / 48.24 | 2.84 | 1,159 | 0 of 6 / 69% |

Run A reproduces the E9 observation (`docs/perf/2026-11-28-export-e9-typing-rerun.md`):
after 2–20 s the first keystroke takes 20–26 ms against 14–15 ms. In run G, at lower
load, the first keystroke after every idle ran on a performance core, and the burst
behind it ran mostly on efficiency cores. The first keystroke was then the fastest of
its burst. Instructions are flat except where faults are high.

### Core type sets most of the time

Keystrokes with fewer than 100 faults, by where their cycles ran:

| Run | Core | n | Instructions M | Cycles M | CPU ms | Handler ms |
|---|---|---|---|---|---|---|
| G | performance (> 90% of cycles) | 124 | 48.15 | 15.65 | 5.15 | 5.15 |
| G | efficiency (> 90%) | 140 | 48.07 | 26.39 | 15.73 | 15.97 |
| A | performance | 20 | 47.90 | 18.72 | 6.27 | 6.67 |
| A | efficiency | 129 | 48.13 | 30.09 | 15.46 | 17.13 |

On an efficiency core the same work takes 1.7 times the cycles at about half the clock,
three times the time. The E9 runs' 11–16 ms for keystrokes 1–9 are efficiency-core
times. Here the main thread ran at user-interactive QoS on efficiency cores while other
processes held the performance cores. Plainsong does not choose the core. Whether a
frontmost app's main thread is placed the same way under the same load is not
measured here: the hosted test app is never active.

### Compression sets the extra work

A first keystroke with 900 or more faults follows an idle in which the kernel
compressed the process's memory. How often that happened, by idle:

| Run | 0.1 s | 1 s | 2 s | 5 s | 10 s | 20 s |
|---|---|---|---|---|---|---|
| A | 0 of 6 | 0 of 6 | 0 of 6 | 3 of 6 | 4 of 6 | 6 of 6 |
| G | 0 of 6 | 0 of 6 | 1 of 6 | 1 of 6 | 1 of 6 | 5 of 6 |

Each such keystroke took 911–1,602 faults and 2.6–15.2 ms of main-thread system time.
By the medians it retired 5.6–12 M more instructions, which is the kernel's
decompression work.

Run B followed the memory. In the seven idles that compressed (all at 10 and 20 s),
the process's compressed memory grew by 14.5–33.0 MiB and its anonymous memory fell by
17.7–41.3 MiB. The first keystroke then decompressed 9.5–15.9 MiB and took 903–1,399
faults, 469–749 of them inside `insertText` and the rest in the SwiftUI update and
layout after it. Its resident size grew by 11.6–17.7 MiB. The keystroke after it
decompressed at most about 1 MiB. Malloc's totals barely changed and its reusable
memory stayed at zero: the pages were compressed, not freed.

## Which memory

**Not the document's buffers.** Run C touched one candidate area after a 12 s idle,
before the first keystroke. In the 8 trials whose idle compressed at least 12 MiB
(`none` twice, `storage` three times, `attributes`, `native`, `malloc`; `copy` drew no
such trial), the touch took 2–149 faults and the first keystroke still took 997–1,298.
So the text storage's UTF-16 string, its attribute runs, the published native source
and the native copy's scratch and result allocations account for at most about 150 of
the first keystroke's 1,000–1,300 faults.

**Small heap pages.** Run D counted the 16 KiB pages that the first keystroke
decompressed, by VM region tag, over ten trials (31–903 pages per trial, 4,604 in all):

| Region tag | Pages | Share |
|---|---|---|
| `MALLOC_SMALL` | 3,866 | 84.0% |
| untagged | 497 | 10.8% |
| unnested shared-region data (tag 35) | 161 | 3.5% |
| Core Animation, malloc, stack, malloc tiny, other | 80 | 1.7% |

None came from the large or medium malloc regions that hold the document's
megabyte-sized buffers. Run E named the blocks on the decompressed malloc pages. In the four
of its ten trials with 602–677 decompressed malloc pages (7.5–8.3 MiB of blocks):

| Blocks on those pages | KiB | Blocks |
|---|---|---|
| non-object, 1–16 KiB | 3,968–4,413 | 592–646 |
| non-object, ≤ 1 KiB | 2,057–2,449 | 24,332–30,975 |
| `__NSCFType` | 176–235 | 2,150–3,478 |
| `__NSCFString` | 122–162 | 2,111–2,825 |
| `_NSViewLayoutAux` | 65–76 | 149–174 |
| `NSKeyValueDependency` | 46–50 | 1,490–1,624 |
| `SwiftUI.PropertyList.Element` | 49 | 318 |
| `NSAutoresizingMaskLayoutConstraint` | 31–36 | 404–464 |

A page lists every block on it, not only the blocks the keystroke read, so this shows
what the decompressed pages hold, not what was read. They hold a cross-section of the
app heap: Core Foundation objects, AppKit layout and key-value-observing objects,
SwiftUI state, and unnamed buffers. The first keystroke after a compressing idle reads
at least one block on each of up to about 900 such pages.

**Cause, not just correlation.** In runs F and H the `keepWarm` arm kept the heap pages
referenced during the idle. Run F, medians of four trials, handler ms, first keystroke
against keystrokes 1–4 (difference):

| Idle | `none` | `regionWalk` | `keepWarm` |
|---|---|---|---|
| 2 s | 5.90 / 6.24 (−0.34) | 5.49 / 5.88 (−0.39) | 5.47 / 5.46 (+0.01) |
| 10 s | 4.89 / 5.41 (−0.52) | 6.54 / 5.78 (+0.75) | 5.30 / 5.74 (−0.44) |
| 20 s | 7.15 / 5.78 (+1.37) | 8.17 / 5.80 (+2.37) | 5.86 / 5.90 (−0.03) |

At 20 s, `none` and `regionWalk` compressed 4.8–19.2 MiB in every trial, and their
first keystrokes took 388–1,382 faults. `keepWarm` compressed nothing in any of its
four trials, and its first keystrokes took 5–78 faults. In one `keepWarm` trial at
10 s the kernel compressed 9.6 MiB anyway, and that keystroke took 959 faults.
`regionWalk` did the same CPU work without the reads and did not help.

Run H repeated the comparison with six trials per cell and the final probe code. Its
first keystrokes all ran on performance cores, and 12–17% of keystrokes 1–4 ran on
efficiency cores. Medians, first keystroke against keystrokes 1–4:

| Idle | Arm | Handler ms | Instructions M | System ms, first | Faults, first | Compressed in the idle, MiB |
|---|---|---|---|---|---|---|
| 10 s | `none` | 6.73 / 5.65 | 49.43 / 47.59 | 0.98 | 321 | 3.8 |
| 10 s | `regionWalk` | 10.70 / 5.81 | 54.60 / 47.56 | 3.40 | 1,035 | 18.3 |
| 10 s | `keepWarm` | 6.79 / 5.70 | 49.67 / 48.12 | 0.46 | 90 | −0.3 |
| 20 s | `none` | 11.18 / 5.96 | 61.05 / 48.32 | 4.36 | 1,308 | 19.4 |
| 20 s | `regionWalk` | 7.40 / 6.03 | 51.24 / 47.68 | 2.65 | 1,023 | 16.3 |
| 20 s | `keepWarm` | 6.02 / 5.82 | 48.79 / 47.64 | 0.44 | 94 | 0.2 |

With the heap kept referenced, the first keystroke after 20 s costs 0.2 ms more than the
next ones, against 5.2 ms with no arm. Its instructions, system time and faults are those
of an ordinary keystroke. The walk without the reads leaves the compression and the cost
in place.

## What Plainsong controls

- **Not the core.** The main thread already runs at user-interactive QoS.
- **Not the compressor.** Keeping 20–30 MiB of heap referenced would mean waking the
  main thread twice a second while the user is idle. It would hold memory back from the
  compressor and move the pressure to other apps, against the platform's memory
  management, to save a few milliseconds once per pause. This PR does not do it.
- **The size of a keystroke.** About 48 M instructions on the main thread, of which
  the native source copy is about 24 M in this document
  (`docs/perf/2026-11-18-keystroke-native-copy.md`). Removing the copy would shorten
  every keystroke, more on an efficiency core. It would not remove the idle cost, which
  comes from heap pages outside the document's buffers. The AppKit and SwiftUI work that
  reads those pages is spread across hundreds of small objects. No single Plainsong
  structure stands out.

On a performance core the cost is smaller. In runs D, E, F and H every first keystroke
ran on a performance core. In the cells whose first keystrokes decompressed (median
faults 600 or more), the first keystroke cost 1.4–5.2 ms more than the next ones. In the
cells with little compression the difference was −0.5 to +1.3 ms. The 17–28 ms in the E9 records combine efficiency-core execution with
decompression. Both are system policies, measured here, and neither is a Plainsong cost
that a change in the editor removes.

## Measuring typing on this Mac

Hosted typing times vary by a factor of three with core placement alone. Compare
instructions, and cycles per core type, before handler times. When handler times are
the budget, record the efficiency-core share. A first keystroke after an idle of 5 s or
more also depends on memory pressure from other processes.

The raw run logs are not committed. Every number above comes from the probe's
`IDLE KEYSTROKE` summary and JSON lines, and from its `IDLE KEYSTROKE HEAP` lines.
