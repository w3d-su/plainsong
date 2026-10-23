# Hosted typing slowdown investigation — 2026-10-22

The measurement summary is
[`docs/perf/2026-10-22-cache-trim-navigation-revalidation.md`](../../perf/2026-10-22-cache-trim-navigation-revalidation.md)
and the design is
[`docs/decisions/2026-10-22-revalidate-cache-trim-navigation.md`](../../decisions/2026-10-22-revalidate-cache-trim-navigation.md).

The retained evidence pack (about 14k lines) left the tree, following #190. No test,
script or document reads it. It remains at commit
[`5a5f3b52eda1f063fd32fe7dd821db425ac4367d`](https://github.com/w3d-su/plainsong/tree/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022),
the head of #197 before this cleanup, reachable through `refs/pull/197/head`. Recover a
file with `git fetch origin pull/197/head` and `git show 5a5f3b52:<path>`. That
commit's [`README.md`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/README.md)
has the full cohort description and the commands to recompute the summary or repeat a
benchmark.

| File at `5a5f3b52` | Contents |
|---|---|
| [`final-typing-runs.csv`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/final-typing-runs.csv) | The 15 final H/F/M runs: controls, geometry, busy and insertion statistics, load, collision count, raw report digest |
| [`typing-runs.csv`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/typing-runs.csv) | All 93 retained final, control, rejected and superseded runs |
| [`mechanism.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/mechanism.json) | Final statistics and paired differences, admission-range validation, H4/F4 per-key arrays and stacks, earlier candidates kept separate |
| [`raw-manifest.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/raw-manifest.json) | Raw report paths, sizes and SHA-256 digests; generator, fixture and manifest digests |
| [`safe-trim-paired-builds.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/safe-trim-paired-builds.json) | Final cohort source, fixture, Mach-O and xctestrun hashes; build flags, toolchain, hardware |
| [`admission-paired-builds.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/admission-paired-builds.json), [`relocation-paired-builds.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/relocation-paired-builds.json) | Provenance for the superseded and rejected candidate cohorts |
| [`safe-trim-H-baseline-test-overlay.patch`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/safe-trim-H-baseline-test-overlay.patch), [`safe-trim-M-baseline-test-overlay.patch`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/safe-trim-M-baseline-test-overlay.patch) | Exact diagnostic and harness overlays applied to the #189 and main baselines, including the identity admission shims |
| [`summarize.py`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/summarize.py) | The final summary generator (its SHA-256 is `raw-manifest.json`'s `generator_sha256`) |
| [`run-safe-trim-pairs.py`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/run-safe-trim-pairs.py), [`run-probes.py`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/run-probes.py), [`build-hosted.py`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/build-hosted.py), [`measure-command.py`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/measure-command.py) | Local campaign helpers, with their original absolute paths |
| [`validation.json`](https://github.com/w3d-su/plainsong/blob/5a5f3b52eda1f063fd32fe7dd821db425ac4367d/docs/evidence/gutter-slow-run-20261022/validation.json) | Local test counts for code commit `73adc68`, style results, the failed Release attempt and raw log digests |

The raw run reports, build logs and result bundles were never committed. They stayed
on the measuring Mac under `/private/tmp/plainsong-gutter-slow-evidence`;
`raw-manifest.json` records their digests.
