# Editor custom themes pass paired typing budgets under normal background load

- Date: 2026-10-29, Asia/Taipei; timing invocations 23:08:06-23:09:06.
- Commit: `d78ef2b0` on `phase3-editor-custom-themes`. All 877 tracked candidate
  App, Packages, PerformanceTests and project.yml inputs match the manifest captured
  after compilation; the following evidence commit changes documentation only.
- Baseline: `4025d1010317d9526de39c0c65c8be27b1e133e3`, fetched immediately before
  baseline preparation at 23:06:12. This campaign rebuilt both products separately.
- Environment: Apple M1 Pro, 16 GiB RAM, macOS 27.0 (26A428), Xcode 27.0
  (27A5194q), arm64, Debug. Neither `CI` nor `GITHUB_ACTIONS` was enabled.
- Fixture: `Fixtures/large-1mb.md`. The `agent.md` section 12 typing budget
  is less than 16 ms.
- Procedure: build separate Debug products, then run the two shared selectors below
  in six interleaved A/B pairs. Run the candidate-only custom-selection selector
  immediately after each candidate shared invocation.
- Result: **pass for the measured typing gate**. All 18 invocations and 30 named
  test executions passed without skips. The shared hosted maximum was 9.190 ms
  on main and 8.162 ms on the candidate; custom-selection maximum was 9.202 ms.
  The paired ordinary-insertion mean increased by 0.553 ms; all paired differences
  and unfavorable samples are retained below.

## Procedure and admission

A is main and B is the candidate. Odd pairs run A then B; even pairs run B then A.
Each pair starts with 1-minute load at most 8 after compilation. There is no lower
bound or idle-machine requirement. Within a pair, retain both products' results
even if load rises; do not discard or retry samples based on latency.
Observed 1-minute load was 6.251-7.294 across all timing invocations, within the
owner's normal 6-8 background load. All six pairs were admitted on their first check.
The raw receipt also records the 5- and 15-minute load averages.

Both products run exactly these shared selectors:

```text
PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget
PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget
```

For example, using the separately built main or candidate manifest:

```sh
xcodebuild -xctestrun <product>.xctestrun \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath <unique-result>.xcresult \
  -only-testing:PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget \
  -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget \
  test-without-building
```

After each B invocation, a separate invocation selects:

```text
PerformanceTests/AppBackedEditorPerformanceTests/testHostedCustomSelectionThemeTypingStaysUnderFrameBudget
```

That case installs custom text/background/caret/selection colors, verifies that
repeated layout does not repeat the selection-container tree scan, then measures
ordinary insertion through the public hosted editor. Its fixture preparation
differs from the shared public-editor case, so it supplies an absolute-budget check,
not a controlled estimate of the cost of selection color.

The runner checks that the session is on-console, logged in and unlocked immediately
before and after every hosted invocation. All those checks passed. Two initial
checks before headless compilation reported a locked session; hosted execution
started only after the unlocked admission succeeded. A temporary `caffeinate`
assertion kept the display awake during the run and was released afterward.
The runner held `/private/tmp/plainsong-xcodebuild-test.lock` throughout native work.

## Shared public-editor samples

Values are milliseconds. Each triple is ordinary insertion / pair insertion /
maximum marked-text update. Differences are B minus A, paired by row.

| Pair | Order | A: ordinary / pair / marked | B: ordinary / pair / marked | Ordinary delta |
|---|---|---|---|---|
| 1 | A, B | 8.307 / 7.497 / 9.190 | 8.081 / 7.378 / 7.369 | -0.226 |
| 2 | B, A | 8.324 / 6.522 / 7.500 | 8.091 / 7.891 / 6.936 | -0.233 |
| 3 | A, B | 7.615 / 7.255 / 6.976 | 8.162 / 5.343 / 5.894 | +0.547 |
| 4 | B, A | 6.404 / 7.829 / 5.433 | 7.803 / 7.306 / 7.597 | +1.399 |
| 5 | A, B | 7.669 / 7.127 / 7.446 | 7.860 / 7.118 / 7.708 | +0.191 |
| 6 | B, A | 6.366 / 8.429 / 7.680 | 8.008 / 7.039 / 7.721 | +1.642 |

The shared pure-editing test prints five per-invocation maxima: Markdown plain
and newline (200 iterations each), Markdown pair (50), MDX plain (200), and MDX
JSX trigger (50). Every raw maximum is in the committed JSON receipt. This table
summarizes those and the three public-editor metrics without omitting slower results.

| Metric | A mean; min-max | B mean; min-max | Paired mean delta | Paired delta min-max |
|---|---|---|---|---|
| Hosted ordinary | 7.447; 6.366-8.324 | 8.001; 7.803-8.162 | +0.553 | -0.233 to +1.642 |
| Hosted pair | 7.443; 6.522-8.429 | 7.013; 5.343-7.891 | -0.431 | -1.912 to +1.369 |
| Hosted marked | 7.371; 5.433-9.190 | 7.204; 5.894-7.721 | -0.167 | -1.821 to +2.164 |
| Markdown plain | 0.003; 0.002-0.003 | 0.003; 0.003-0.004 | +0.001 | 0.000 to +0.001 |
| Markdown newline | 0.066; 0.040-0.085 | 0.058; 0.044-0.106 | -0.008 | -0.031 to +0.021 |
| Markdown pair | 0.210; 0.160-0.297 | 0.272; 0.168-0.365 | +0.062 | -0.118 to +0.199 |
| MDX plain | 0.003; 0.001-0.008 | 0.001; 0.001-0.001 | -0.002 | -0.007 to 0.000 |
| MDX JSX trigger | 0.188; 0.131-0.229 | 0.192; 0.127-0.338 | +0.005 | -0.102 to +0.110 |

The ordinary-insertion paired median is +0.369 ms. Its +0.553 ms mean and
largest +1.642 ms pair are smaller than main's 1.958 ms run-to-run range.
Pair and marked-text means decreased. These six pairs meet the absolute budget
and the existing comparison against run-to-run variation; they do not prove
zero cost or statistically establish equivalence. In particular, retain the positive
ordinary-insertion delta when assessing future performance changes.

## Load and supplemental custom-selection samples

The load columns show the 1-minute average immediately before and after each
invocation. B-custom ran immediately after B-shared in the stated pair order.

| Pair | A-shared load | B-shared load | B-custom load | B-custom ordinary (ms) |
|---|---|---|---|---|
| 1 | 6.251 -> 6.311 | 6.311 -> 6.286 | 6.286 -> 6.286 | 9.202 |
| 2 | 6.972 -> 6.972 | 6.286 -> 7.144 | 7.144 -> 7.144 | 6.603 |
| 3 | 6.972 -> 7.294 | 7.294 -> 7.110 | 7.110 -> 7.110 | 9.109 |
| 4 | 6.940 -> 6.625 | 7.110 -> 6.940 | 6.940 -> 6.940 | 8.944 |
| 5 | 6.625 -> 6.574 | 6.574 -> 6.574 | 6.368 -> 6.368 | 8.539 |
| 6 | 6.578 -> 6.532 | 6.368 -> 6.578 | 6.578 -> 6.578 | 7.005 |

The custom-selection samples are all below 16 ms. They exercise the custom chrome
path that a built-in-only A/B would miss, including the cached container lookup.
No latency sample failed, was discarded or was replaced.

## Verification and retained evidence

For the same product/test inputs as `d78ef2b0`:

- `make format` and `make lint` passed with SwiftFormat 0.62.1 first on PATH.
  Five unrelated formatter rewrites were restored. Lint reports 462 warnings and
  zero serious violations. The first lint attempt, before splitting the enlarged
  rejection table into a separate test, failed; that log is preserved.
- `make test -o test-hosted` passed the headless portion: MarkdownCore 366,
  EditorKit 534 (9 skips), PreviewKit 211 (3 skips), WorkspaceKit 384,
  SyntaxKit 12, WorkspaceCore 29. Total 1,536 executed, 12 skipped, zero failures.
  Tooling ran 86 tests; preview ran 221; both sandbox probes passed.
- The hosted portion then ran serially from the built candidate manifest.
  Focused `EditorThemeImportTests`: 10 executed, no skips or failures.
  Full `PlainsongTests`: 1,075 executed, 16 skips, zero failures.
  Full `PerformanceTests`: 32 executed, 4 skips, zero failures.
  Full hosted execution finished at 23:13:59 with exit 0; the unlocked-session
  check immediately afterward also passed. No `PlainsongUITests` executed.
- `make build`, candidate and fresh-main `build-for-testing`, and
  `git diff --check` passed.

The compact receipt is
`docs/evidence/editor-custom-themes-20261029/typing-ab.json`. It includes the
environment, exact command arguments and exit statuses, every raw timing metric,
load/session observations, source identity, and verification totals.
The SHA-256 of the full captured candidate source manifest is
`b46f4c133025eed88f987f1df55f02386b12c4fc79e9798eb6a87afa4d6e1e5d`.
Logs, result bundles, the full source manifest, baseline archive, runner and copied
test manifests remain at `/private/tmp/plainsong-theme-review4-20261029/`,
outside DerivedData. Both session-created DerivedData trees are removed after
verification; the cleanup receipt is retained with those logs.

These results close the local automated T1-T3 checks. Required CI must still pass
on the published head. T7 contrast warnings and owner keyboard/VoiceOver/real
Increase Contrast smoke remain open; preview/bridge/export work remains in PR C.

## Earlier cancelled and interrupted attempts

The earlier attempt at
`/private/tmp/plainsong-theme-final-review-20261029/` remains historical evidence.
At 22:42:32, before its first timing invocation, the session reported
`CGSSessionScreenIsLocked = 1`, with lock timestamp 22:33:05. Admission exited
75 without starting a performance test. Its load was 18.01 / 56.51 / 41.97;
preceding post-build 1-minute observations ranged from 69.22 down to 22.01.
It produced no accepted or discarded latency samples.

That attempt compiled candidate `1b02470a` against then-main
`cd2af1ad93bd539aac8d29fa9a50382b9779ed36`, before main advanced to `4025d101`.
Its cutoff below 20 excluded a compiler overload; it was not a normal-load
acceptance threshold. Earlier Windows A/B records are procedure references,
not this campaign's numerical baseline. The successful campaign above rebuilt
current main and started every pair at load at most 8.

The earlier ten import tests passed at 22:36:18 while the session was locked;
they did not satisfy unlocked-session acceptance. The focused unlocked rerun above
supplies that evidence. An even earlier full hosted attempt stopped after an
NSSavePanel semaphore timeout, WebKit `renderFailed(timeout)` and preview-find
timeout; retain it as interrupted evidence. The later complete run does not turn
those earlier attempts into passes.
