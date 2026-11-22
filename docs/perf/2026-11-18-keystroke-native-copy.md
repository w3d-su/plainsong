# The per-keystroke native source copy, and the slow first keystroke after a pause

- Date: 2026-11-18
- Commit: fix `fe686817` (measured as `b1a704d8`, the same tree before a message-only
  amend); baseline `main` at `2af666cb` with the same probe file added.
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro (MacBookPro18,3),
  testable Release (`-O`, `ENABLE_TESTABILITY=YES`). One-minute load 4–29 during the
  baseline runs and 35–410 during the fix runs, from other processes, so wall times
  are not compared; retired instructions are, and they barely depend on load.
- Fixture: `Fixtures/kitchen-sink.md` (3.4 KB), `perf-100kb.md`, `perf-500kb.md`,
  `large-1mb.md`. Budget: `agent.md` §12 typing < 16 ms, and its rule of no
  O(document) work per keystroke on the main thread.
- Procedure: `AppBackedEditorPerformanceTests/testFirstKeystrokeAfterAnIdlePause` with
  `TEST_RUNNER_PLAINSONG_RUN_IDLE_KEYSTROKE_PROBE=1`, `…_FIXTURE=<file>` and
  `…_REPETITIONS=12` (1 MiB) or `6`, built with `xcodebuild … -configuration Release
  ENABLE_TESTABILITY=YES build-for-testing` and run with `test-without-building`.
- Result: the copy no longer measures the length with a separate pass. A keystroke in
  the 1 MiB document retires 47.9 M main-thread instructions instead of 68.8 M, and the
  first keystroke after a pause no longer runs 31% more cycles than the next ones.

## Where it came from

The E9 typing probe (`docs/perf/2026-11-18-export-e9-typing-isolation.md`) found that,
with no export at all, the first keystroke after about a second of idle took 20–33 ms in
the 1 MiB document against 12–15 ms for the next ones.

The probe here waits 0.1–4 s, then types four keystrokes 80 ms apart, and records for
each keystroke the hosted §12 measure plus the main thread's CPU time and its retired
instructions and cycles (`thread_selfcounts`, looked up at run time; test code only).

Baseline, medians, positions 1–3 against the first keystroke after at least 0.7 s idle:

| Document | Instructions, steady / first | Cycles, steady / first | Handler ms, steady / first |
|---|---|---|---|
| 3.4 KB | 21.51 / 21.97 M | 19.98 / 20.10 M | 11.18 / 12.12 |
| 100 KB | 26.21 / 26.36 M | 23.80 / 22.93 M | 14.52 / 13.22 |
| 500 KB | 43.95 / 44.02 M | 28.46 / 27.33 M | 17.11 / 15.66 |
| 1 MiB | 68.75 / 69.20 M | 28.37 / 37.22 M | 15.91 / 22.94 |

Two things follow. A keystroke retires about 21 M fixed instructions plus about 45 per
byte of document, on the main thread. And the first keystroke after a pause retires the
same instructions as the next ones but needs more cycles at the same clock, which is cold
caches, not extra work and not a lower clock; it shows only where the per-byte work is
large.

A 30 s `sample` of the baseline host while typing continuously in the 1 MiB document put
3,510 of the 4,395 main-thread samples under `insertText` in `ExactSourceText.nativeCopy`,
called from `MarkdownTextViewCoordinator.syncTextFromTextViewIfNeeded` through
`textViewDidChangeSelection`. It ran `CFStringGetBytes` twice over the whole document: once
with no buffer to measure the UTF-8 length, once to convert.

## The change

One `CFStringGetBytes` pass into a scratch buffer of three bytes per UTF-16 unit (the
UTF-8 worst case), then an exact-size copy into the string. CoreFoundation still does the
conversion, so unpaired surrogates are still refused. A standalone `-O` benchmark on the
same `NSTextStorage` string class, median of 31 runs:

| 1 MiB of | Two passes | One pass | Word-at-a-time transcoder (rejected) |
|---|---|---|---|
| ASCII | 3.36 ms, 46.0 M | 1.50 ms, 24.9 M | 1.02 ms, 17.9 M |
| Chinese | 5.69 ms, 78.6 M | 3.68 ms, 58.6 M | 4.40 ms, 67.0 M |
| Emoji | 3.73 ms, 46.7 M | 1.65 ms, 30.5 M | 1.74 ms, 28.2 M |

A hand-written transcoder won only on pure ASCII, lost on Chinese, and would have meant
about fifty lines of encoding code on the keystroke path.

## Result

| Document | Instructions per keystroke, before → after | First keystroke after ≥ 0.7 s: cycles, before → after |
|---|---|---|
| 3.4 KB | 21.51 → 21.79 M | 20.10 → 22.18 M |
| 100 KB | 26.21 → 24.47 M | 22.93 → 21.89 M |
| 500 KB | 43.95 → 34.53 M | 27.33 → 25.65 M |
| 1 MiB | 68.75 → 47.94 M | 37.22 → 29.04 M |

The per-byte cost falls from about 45 to about 24 instructions. At 1 MiB the first
keystroke after a pause now runs 4.5% more cycles than the next ones, against 31% before,
and its handler median fell from 22.94 to 16.04 ms even under the much heavier load.

The copy is still O(document): about 1.5 ms per MiB of ASCII and 3.7 ms per MiB of
Chinese at full speed. Applying each edit to the previous native string instead would
remove it, at the cost of keeping that string exactly in step with the text storage
through IME, Undo and source reconciliation; that is not done here.

`ExactSourceTextTests` adds a seeded differential test over 2,000 random UTF-16
sequences (encoding boundaries, CJK, valid pairs and lone surrogates at any position).
With the refusal check removed, the suite reports 1,613 failures.
