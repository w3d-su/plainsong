# Editor custom theme typing acceptance is still open

- Date: 2026-10-29, Asia/Taipei.
- Candidate source: `1b02470a5368faeadbeeff1b788be92e737a8fe4`. The commit
  adding this record changes documentation only.
- Baseline: main at `cd2af1ad93bd539aac8d29fa9a50382b9779ed36`, captured
  before main advanced to `4025d101` during verification.
- Environment: Apple M1 Pro, 16 GiB RAM, macOS 27.0 (26A428), Xcode 27.0
  (27A5194q), Debug.
- Fixture: `Fixtures/large-1mb.md`. The `agent.md` section 12 typing budget
  is less than 16 ms.
- Result: **not measured**. Both products compiled, but the display-session
  admission refused execution. T3 typing acceptance remains open.

The intended comparison uses separately built products and six interleaved A/B
pairs. Odd pairs run main first; even pairs run the candidate first. Both products
run the same two selectors:

```text
PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget
PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget
```

After each candidate run, a separate invocation would additionally execute:

```text
PerformanceTests/AppBackedEditorPerformanceTests/testHostedCustomSelectionThemeTypingStaysUnderFrameBudget
```

That additional case exercises a custom selection color, including the cached
selection-container lookup. It is supplemental absolute-budget evidence: its
fixture preparation differs from the shared public-editor test, so their numbers
must not be presented as a controlled selection-color comparison.

The prepared command is:

```sh
xcodebuild -xctestrun <product>.xctestrun \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath <unique-result>.xcresult \
  -only-testing:PerformanceTests/PerformanceBudgetTests/testTypingLatencyStaysUnderFrameBudget \
  -only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget \
  test-without-building
```

Every invocation would record its start time, before/after load averages, exit
status, named test totals, and every printed metric. Neither `CI` nor
`GITHUB_ACTIONS` is enabled. No idle-machine requirement is imposed. Compilation
caused a transient overload, so admission waited for the 1-minute load to drop
below 20, recording all observations rather than starting a timing sample during
that spike.

At 22:42:32, immediately before the first sample, the session reported
`CGSSessionScreenIsLocked = 1`. The lock timestamp was 22:33:05. Admission exited
75 without starting a performance test. The last recorded load was
18.01 / 56.51 / 41.97 (1 / 5 / 15 minutes); preceding post-build observations
ranged from 69.22 down to 22.01 for the 1-minute average. These are environment
observations, not typing measurements. There are no accepted or discarded latency
samples in this attempt.

The initial display check at 22:28 showed an unlocked, logged-in console session.
The later lock occurred while the required `make test` was compiling its hosted
products. Its ten `EditorThemeImportTests` passed at 22:36:18, including FIFO,
workspace-notification and picker-section cases. Retain that executed result, but
repeat the focused hosted acceptance with the screen unlocked: this run does not
satisfy the owner's unlocked-session requirement.

Required format, pinned lint, package/preview/tooling tests, app build and
`git diff --check` passed for the candidate source. No `PlainsongUITests` executed.
The earlier interrupted full hosted run remains historical failed/interrupted
evidence; this focused run does not replace it.

Logs, result bundles, the candidate source manifest, the baseline source archive,
runner scripts, and load/session admission records are retained outside DerivedData
at `/private/tmp/plainsong-theme-final-review-20261029/`. Both session-created
DerivedData directories are removed after the attempt. A future unlocked run must
rebuild and complete the paired measurements before closing T3; package tests or a
compiled frame-budget assertion do not close it.
