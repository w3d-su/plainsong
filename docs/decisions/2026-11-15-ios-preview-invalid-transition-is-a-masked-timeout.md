# iOS preview tests: `InvalidTransition` is a masked wait failure

Date: 2026-11-15. Follow-up to
[2026-10-25-ios-preview-wait-diagnostics](2026-10-25-ios-preview-wait-diagnostics.md),
which left the origin of `InvalidTransition` unconfirmed.

## Decision

- Read `caught error: "InvalidTransition { phase: idle, targetPhase: failed(deinit) }"`
  in an `IOSPreview` result as "the test threw after its `PreviewController` was torn
  down". The error the test actually threw is in the `PREVIEW_TEST_DIAGNOSTIC` lines
  just above it in `test.log`.
- The 8-second throwing wait and the 2-second JavaScript reply deadline stay as they
  are, and no warm-up load is added. The hosted failure below is not fixed by this
  entry.
- `ios.yml` stays manual dispatch.

## Why

The hosted `ios.yml` run on `main` `1d8449f8` (run 43629938430, attempt 1) failed
`PreviewIOSHostedTests/testBundledKitchenSinkAndMDXStayVisible` with that error. Its log
shows, in order: the WebKit GPU process relaunching after an idle exit and taking 8.16 s
(its earlier launches in the same session took 1.1–1.7 s); a `JavaScript reply`
`callback-deadline-error`; the `kitchen sink` wait rethrowing it; then XCTest reporting
`InvalidTransition`. Attempt 2 on the same head passed all 214 cases. It was not a first
load: many WebKit cases had already run in that process.

A temporary probe case, run locally in the `IOSPreview` suite on an iPhone 17 Pro /
iOS 27.0 simulator and not committed, held the page busy for 5 s so that one reply
missed the 2 s deadline:

| Variant | XCTest reported |
|---|---|
| Throw the wait's timeout error with no web view | the timeout |
| Callback gate deadline with no web view | the timeout |
| Missed reply, bare call, controller kept alive, no shutdown | the timeout |
| Missed reply inside `until`, controller kept alive, no shutdown | the timeout |
| Missed reply inside `until`, `defer { shutdownForTesting() }` | `InvalidTransition` |
| Missed reply, bare call, `defer { shutdownForTesting() }` | `InvalidTransition` |
| Busy page, explicit `shutdownForTesting()`, then throw a plain timeout error | `InvalidTransition` |

So the report changes whenever the controller is shut down and released while a test
error propagates, whatever that error is. The helper is not involved.

## What is not established

- Whether the shutdown or the release of the web view is what changes the report: the
  cases that kept the timeout did neither. Every such case also had a script still
  running in the page; a shutdown with an idle page was not tried.
- The mechanism inside XCTest or UIKit. The name comes from a private framework.
- Why the GPU process took 8.16 s once. It is one occurrence on one hosted runner.
- Why the failing hosted case ran for another 9 s after its deadline error. The local
  probe ended at once.
- The probe ran on iOS 27.0 only. The hosted failure was on an iOS 26 runtime.

## Alternatives considered

- Lengthen the reply deadline, or warm the GPU process before the suite: both are ruled
  out by `docs/ios/evidence/lane-07/ready-repair-20261015/README.md` and agent.md §14.
- Let `until` treat a missed reply as "not yet" and keep polling inside its 8 s: it keeps
  both numbers but ends the rule that helpers rethrow the original error
  (2026-10-25 entry). It is the owner's call and is not taken here.
- Retry the preview step in the workflow: a green rerun does not replace a root cause
  (`docs/ios/README.md`).
- Record the original error as an XCTest failure inside the helper: the deadline tests
  expect those timeouts and would fail.
- Run `ios.yml` on pull requests now: one unexplained failure in one run is too little
  to judge its rate, and a required check that fails at random costs reruns.
