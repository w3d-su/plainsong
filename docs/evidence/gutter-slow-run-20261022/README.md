# Hosted typing slowdown investigation — 2026-10-22

This pack retains the final five interleaved H/F/M triplets, formation controls,
rejected candidates, source/build provenance and the scripts used to collect and
summarize them. The measured fix is commit
`73adc68cd3535a92e0f267cc3389173beb9d7c69`. Its production change revalidates each
cache-trim chunk against the native viewport and selected paragraphs, and keeps
selection-only callbacks from continually postponing the trimmer.

The final campaign used optimized Debug (`SWIFT_OPTIMIZATION_LEVEL=-O`,
`GCC_OPTIMIZATION_LEVEL=s`) on an Apple M1 Pro, 8 cores, 16 GiB RAM, macOS 27.0,
Xcode 27.0 build 27A5194q. One-minute load measured at run start/end ranged from
5.30 to 32.22. There was no idle-load gate. The screen was unlocked for the
app-hosted tests. No PlainsongUITests or XCUITest was executed.

## Final cohort and results

| Label | Tested product |
|---|---|
| H | PR #189 reference `808190415ec80fa30acb0c81e206025343349177`, with diagnostic/harness overlay and test-only identity admission shim |
| F | Fix `73adc68cd3535a92e0f267cc3389173beb9d7c69`, using the actual production admission planner |
| M | Main `2138165e703644f87494518fb113e11f5dcc04e1`, with equivalent diagnostic/harness overlay, native-gutter adaptation and identity admission shim |

The hosted source-only probe makes 50 native insertions in `Fixtures/large-1mb.md`.
The controlled formation sequence requests at most 30 reverse 32768-unit trims,
scrolls to the middle after chunk 16, settles for 10 ms, yields for 1 ms between
chunks, and directly draws the gutter after every trim. With
`PLAINSONG_SCROLL_PROBE_USE_ADMISSION=1`, F asks the real planner before each
attribute edit; the old H/M policies admit the proposed range through their
AppTests-only identity shims. Both baseline overlays retain their original
production admission and coordinator logic, with a diagnostic trimmer hook.

These inputs reproduce the vulnerable ordering. They do not make every reference
run slow: H reproduced the large refill once in five final runs. The paired orders
were HFM, FMH, MHF, HMF, FHM.

| Round | H busy ms | F busy ms | M busy ms | F−H | F−M |
|---|---:|---:|---:|---:|---:|
| 1 | 2080.9 | 1966.4 | 3440.8 | −5.50% | −42.85% |
| 2 | 2165.5 | 2131.8 | 3476.8 | −1.56% | −38.69% |
| 3 | 2122.1 | 2079.2 | 3459.7 | −2.02% | −39.90% |
| 4 | 4932.9 | 2149.8 | 3498.4 | −56.42% | −38.55% |
| 5 | 1974.8 | 1995.0 | 3757.0 | **+1.03%** | −46.90% |

Median run busy time was H 2122.1 ms, F 2079.2 ms, M 3476.8 ms. Median of the
per-run synchronous insertion medians was H 5.975 ms, F 5.799 ms, M 5.753 ms.
Busy time includes scheduled main-thread work; insertion duration measures only
the synchronous `insertText` call. Treat each run as the comparison unit, not its
50 keys as independent trials. F exceeded ordinary fast H busy time once by
20.25 ms (+1.03%); the ordinary paired insertion-median differences ranged from
−0.321 to +0.326 ms. These results do not establish that F is faster in every run.

H4 is retained as the slow representative in `mechanism.json`: key index 4
requested 10896 paragraphs through source offset 903133; the run's insertion
median rose to 40.249 ms. F4 had a 6.226 ms insertion median. F's peak paragraph
request count was 1474 in all five runs. Large refill episodes occurred in H 1/5,
F 0/5, M 0/5. Main formation controls stayed fast, so this evidence does not show
that #189 is unrelated to the original slowdown.

All 390 explicit ranges have same-turn before-state captures and pass bounds,
maximum length and descending-order checks. H/M each admitted 30 ranges per run;
each run released one chunk overlapping selected paragraphs plus their margin,
and 13 chunks overlapping the protected viewport prefix/prefetch, including one
native-viewport overlap. F admitted 18 ranges per run, with zero such overlaps.
The two post-navigation F ranges are `[483520,516288)` and `[470119,483520)` in
the retained H4/F4 comparison. The planner skips the selected-paragraph interval
and stops before the live viewport/prefetch boundary. This also avoids protecting
all earlier text merely because the user left an offscreen caret at document end.

## Candidate identities

Only `safe-trim-paired-*` is the final cohort. Earlier results remain separate in
`typing-runs.csv` and `mechanism.json`; they are not pooled into the final table.

- `admission-paired-*`: **SUPERSEDED** suffix-only guard. Its unavailable-viewport
  fallback and offscreen-caret policy were replaced by the final interval planner.
- `relocation-paired-*` and `relocation-stress-*`: **REJECTED** height adapter.
- `paired-split16-*` and `forced-draw*-F`: **REJECTED** viewport-snapshot gutter.
- Formation and reproduction controls retain their source-cohort labels.

The rejected snapshot candidate still reproduced a 5299 ms slow run while its draw
made no TextKit requests. A matched-width, gutter-off reference reproduced
5325 ms. Draw-time enumeration alone therefore does not explain the large refill.
The final trace instead exposes stale trim ranges overlapping newly relevant
TextKit state. Main's old-policy controls also collide with protected ranges while
remaining fast, so those collisions do not force the rare mode on every layout.

## Files and provenance

- `final-typing-runs.csv`: 15 final runs, with controls, geometry, busy/insertion
  statistics, load, collision count and raw JSON digest.
- `typing-runs.csv`: 93 retained final/control/rejected/superseded runs.
- `mechanism.json`: final statistics and paired differences, all final admission
  validation, representative per-key arrays/stacks, and separate old candidates.
- `raw-manifest.json`: raw report paths, sizes, SHA-256 digests, source cohort,
  generator digest, fixture digest and build/overlay manifest digests.
- `safe-trim-paired-builds.json`: final source, fixture, app MachO,
  PlainsongTests/PerformanceTests MachO and xctestrun hashes; build command,
  flags, toolchain, hardware and baseline overlay hashes.
- `admission-paired-builds.json` / `relocation-paired-builds.json`: retained
  provenance for those earlier candidate cohorts only.
- `safe-trim-H-baseline-test-overlay.patch` /
  `safe-trim-M-baseline-test-overlay.patch`: exact baseline tracked and untracked
  diagnostic/harness overlays, including the identity admission shims.
- `summarize.py`: unchanged bytes of the final generator; its SHA-256 matches
  `raw-manifest.json`'s `generator_sha256` despite the shorter filename.
- `run-safe-trim-pairs.py`, `run-probes.py`, `build-hosted.py`,
  `measure-command.py`: local campaign helpers retaining the original absolute
  worktree, DerivedData and evidence paths. Their bytes are unchanged except that
  the paired runner omits its final extra blank line.

Each campaign manifest binds only the source paths it lists. The final manifest
cannot attest an older binary; exploratory rows without a matching retained
manifest leave binary attestation blank. F's measured source was clean at the
commit above. The two hashed overlay patches bind the H/M modifications to their
base commits. The large raw reports and build/run logs remain under
`/private/tmp/plainsong-gutter-slow-evidence`; they are not included in this pack.
The overlay patches retain the context-prefix spaces required by unified diff;
whitespace-only checks exclude `*.patch` while preserving their exact hashed bytes.
Those are local evidence locations, not portable public links. Copy/archive the
raw bulk separately if an independent reviewer needs to recompute every metric.

## Recompute the summary

Run from the repository root with the retained raw evidence available:

```sh
python3 docs/evidence/gutter-slow-run-20261022/summarize.py \
  --input-dir /private/tmp/plainsong-gutter-slow-evidence \
  --output-dir /private/tmp/plainsong-gutter-slow-recomputed \
  --fixture Fixtures/large-1mb.md
```

The copied generator's default input directory is now this documentation folder,
which contains no raw run reports. Pass `--input-dir` explicitly. The command
recomputes the summary from the 93 retained raw files whose SHA-256 digests are
listed in `raw-manifest.json`. It refuses an incomplete final 15-run cohort,
changed fixture/overlay digests, missing exact before-state captures, invalid
ranges, or final F protected-range collisions. `--allow-partial` is draft-only and
was not used for the retained final output. The generator runs no benchmark.

## Repeat a benchmark

The retained helpers describe the actual local campaign; the final extra blank
line normalization noted above changes no command. Review their paths
before use; editing those paths or changing a product creates a new run with new
source/product hashes. Preserve these originals, write new evidence to a separate
folder, and regenerate provenance for any new campaign.

For an optimized app-hosted build, set the paths for the selected variant, then run
from that worktree:

```sh
benchmark_tree=/absolute/path/to/variant/blogeditor
benchmark_dd=/private/tmp/plainsong-new-benchmark-dd
cd "$benchmark_tree"
xcodegen generate
/usr/bin/lockf -k /private/tmp/plainsong-xcodebuild-test.lock \
  xcodebuild -project Plainsong.xcodeproj -scheme Plainsong \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$benchmark_dd" \
  SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s \
  -parallel-testing-enabled NO -skip-testing:PlainsongUITests \
  -only-testing:PlainsongTests -only-testing:PerformanceTests build-for-testing
```

With an unlocked screen, run only the source-only app-hosted probe:

```sh
TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1 \
TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_LINE_NUMBERS=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_CHUNKS=30 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_SCROLL_AFTER=16 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_YIELD_MS=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_DRAW_AFTER_TRIM=0 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_USE_ADMISSION=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_USE_PRODUCTION_TRIM=0 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_PARAGRAPH_TRACE=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_TRACE=1 \
TEST_RUNNER_PLAINSONG_SCROLL_PROBE_CAPTURE_BEYOND_OFFSET=600000 \
/usr/bin/lockf -k /private/tmp/plainsong-xcodebuild-test.lock \
  xcodebuild -project Plainsong.xcodeproj -scheme Plainsong \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$benchmark_dd" -parallel-testing-enabled NO \
  -skip-testing:PlainsongUITests \
  -only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedSourceOnlyTypingMainThreadBusySlices \
  test-without-building
```

The local paired runner also wraps the locked command with
`measure-command.py`, which records load immediately before and after execution;
`run-probes.py` retains the JSON and log for each tag. Its paired runner uses the
five orders above and records each variant's actual admitted ranges. Preserve both
busy and insertion metrics when comparing a new campaign.

The local validation report is [`validation.json`](validation.json): all four Swift
package groups and both app-hosted XCTest bundles passed. It also records the
unsuccessful optimized SwiftPM Release attempt and old-production control, style
results and raw log digests. These measurements do not certify owner manual/IME/
device acceptance or exact-head CI. CI is intentionally skipped to honor the
no-XCUITest restriction; no merge-readiness claim is made.
