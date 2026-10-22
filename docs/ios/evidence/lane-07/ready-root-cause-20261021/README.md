# Lane 07 real-bundle readiness: retained observations — 2026-10-21

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../../README.md); run historical local-path commands from that restored checkout.

**The app-hosted readiness gate passes; the platform cause remains unproven.**
The public `make ios-preview` run executed **94 Passed, 0 Failed, 0 Skipped**
on `bd3dadcf5e0dd39e83896d6c463e285e8a0d6cb3`. Independent review re-extracted
all original named cases from its complete `Results.xcresult` and matched all
**684** captured source records to that Git tree. The driver returned 0,
the built test image was app-hosted, and resource preflight passed.

This is historical simulator evidence for that tree, not an execution of
the later #164 aggregate or main integration. This PR adds evidence and
documentation only. It changes no product code, assertions, timeouts,
fixtures, host, scheme, bridge, CSP, or production providers.

## Source and environment

The tested tree merges #176 `69d499ca356488b7487965812a8a9d57b735eab7`
with #173 `af389cb7e054dca9fb182841f6fa8c440417300a`. The public runner
recorded a clean tree, Xcode 27.0 (27A5194q), an iOS 27.0 simulator and
`IOSPreviewTestHost.app`. No iOS 26 runtime or device result is inferred.

The full suite's bundle case passed in **1.942 s**, after earlier WebKit
cases; it is not a first-WebView measurement. In a separate selected hosted
run it was the first selected test and passed in **2.993 s**. That run has
two production tests and two diagnostic probes (all four Passed), but no
retained run-bound source manifest. Production acceptance keeps the original
**8 s** readiness and **2 s** JavaScript deadlines.

The independent October 19 first-controller receipt on
`5f373ab66a3eb9dd2b47a1657485a27651606469` remains a separate source-bound
measurement (2.758 s), not this run's measurement.

## What the probes observed

Hostless logs report that the process has no `UIApplication`. Several first
default-store loads did not become ready within the diagnostic 20 s window;
later loads often completed sooner. This is an association in these runs.
It does not establish that missing `UIApplication`, RunningBoard, or one
particular WebKit mechanism caused every historical timeout.

Temporary probe sources survive under `probes/` and match their original
scratch copies byte for byte. They mostly print timing instead of asserting
readiness: a Passed diagnostic case that prints `ready=never` is a completed
observation, not a passing readiness assertion. Their 20 s loops and optional
10 s diagnostic JS calls do not replace the production 8 s / 2 s limits.

| Run | Observed order | Observation |
|---|---|---|
| v1 | Raw real/tiny views after selected controller cases | Later raw views loaded; this does not reproduce the original first-controller path. |
| v2 | Controller first, raw variants later | Controller printed `readyAt=never`; later real-all configuration printed 0.660 s. The controller probe itself was marked Passed. |
| v3 | Raw default-store real-all first, controller last | First raw view printed `ready=never`; later controller printed 0.736 s. |
| v4 | First default-store real-all after 25 s idle | Start 2.452 s, commit 5.271 s, no finish within the diagnostic window. That idle delay did not avoid the observation in this run. |
| v5 | Default-store real-all first; nonpersistent-1 second; nonpersistent-2 third; tiny fourth | First view printed `ready=never`; subsequent nonpersistent views printed 0.930 / 0.889 s; tiny printed 4.520 s with two diagnostic JS errors. |

In v5, `testPPNonPersistentFirst` means the first *nonpersistent* test, not
the first view in the process. Those cases load tiny HTML, while the preceding
default-store case loads the real bundle. Order, content and data store vary
together; this is not a controlled first-view nonpersistent comparison.

Successful later raw loads do not rule out resource, configuration or
controller defects in another ordering/build/historical failure. Modified
probe runs have archived sources and logs, but no immutable per-run input
manifests. A compiler path alone cannot certify their compiled bytes.

## Export failures and historical boundaries

The retained app-hosted full94 result passes all three earlier failing names:

- `ExportHTMLHostedTests/testMDXPlaceholdersExportWithoutComponentExecution`
- `ExportHTMLOfflineTests/testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument`
- `ExportHTMLOfflineTests/testOfflineReopenRendersEmbeddedResourcesWithoutNetwork`

Their historical individual causes remain unproven. A hosted pass and a
similar hostless stall do not prove a shared cause or exclude every product
defect. #173 separately fixes a real harness issue: navigation/readiness
failure throws before subsequent JavaScript, callbacks are bounded, and
cleanup is installed before awaiting. This packet does not certify that no
other export defect exists.

The unmodified `59f374f` baseline and earlier interrupted instrumentation
runs remain separate evidence. An interrupted driver or an xcresult without
`Info.plist` is not a parseable result. These probes do not diagnose the
historical 53.41 GB allocation or restore missing historical instrumentation.

## Hostless full-suite result

The retained `PreviewKit-Package` full run is a complete **94-case** result:
**58 Passed, 36 Failed, 0 Skipped**. Several iOS fixtures explicitly refuse
missing packaged app resources and name `make ios-preview`. That failure path
differs from the original readiness timeout and cannot reproduce its cause.

The public runner admits `IOSPreview` for iOS preview acceptance and refuses
hostless package/library schemes. This established contract does not imply
that every use of WebKit outside an app is unsupported.

## Independent evidence review

The original 16 checksum records match. Eight complete xcresults were
recovered, copied before parsing, and re-extracted:

| Result | Passed | Failed | Skipped | Use |
|---|---:|---:|---:|---|
| Public app-hosted full suite | 94 | 0 | 0 | Required-name and no-skip gate passed |
| Selected hosted controller + probes | 4 | 0 | 0 | Modified diagnostic run |
| Hostless full suite | 58 | 36 | 0 | Failures preserved |
| Hostless v1 selected cases + probes | 2 | 2 | 0 | Modified diagnostic run |
| Hostless v2 / v3 / v4 / v5 | 7 / 7 / 2 / 4 | 0 | 0 | Diagnostic completion only; read printed readiness |

The recovered Mac raw log matches the SHA-256 in `mac-previewkit.txt`:
**94 Passed, 0 Failed, 0 Skipped** on the stated historical tree. This is not
a new Mac execution.

`review-20261021.json` indexes the verification. Original public source,
driver, metadata, test-results, gate, required-name copy, admission and resource
records are under `logs/`. All 684 records and the required-name copy match
Git tree `bd3dadcf`. Probe text files are not compiled into the suite.

Complete recovered xcresults, fresh extractions, the verification script
and file hashes are retained locally under:

`/Users/davis._.su/.codex/visualizations/2026/10/08/01a11aa3-ca4c-7832-aa4e-1a1bf0fbe88d/ios-main-integration-20261021/lane07-retained/`

The earlier ellipsized archive locator was not reproducible. Review instead
recovered the original scratch bundles. Another machine needs those bundles
to repeat xcresult parsing; the committed manifests/logs remain inspectable.

```sh
(cd docs/ios/evidence/lane-07/ready-root-cause-20261021 && shasum -a 256 -c SHA256SUMS)
```

## Current integration and remaining gates

#173, #176 and #175 have merged into the #164 review branch. This PR was
synchronized with #164 `fdd2a071c04f61f5259d31cf17699534d77fce9e` using a merge
commit. All five incoming Decision Log rows are retained once; product and
test source remains byte-equal to that aggregate.

Exact-head CI is reported by the live PR check. Historical full94 evidence
is separate from CI, and Mac CI does not run this UIKit gate.
M0 iPhone/iPad IME/Undo, Files/iCloud/offline/conflict/background persistence,
owner re-sign/install, production composition, composed-app acceptance,
performance, accessibility, current-head release IPA and iOS 26 runtime remain
open. The app still uses unavailable C0 capabilities.
