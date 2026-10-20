# Lane 07 real-bundle readiness: root cause — 2026-10-21

**Result: the real-bundle readiness gate passes in the app-hosted process.**
`make ios-preview` (scheme `IOSPreview`, host `IOSPreviewTestHost.app`) executed
**94 / 94 passed, 0 failed, 0 skipped**. The first controller,
`PreviewIOSHostedTests/testBundledKitchenSinkAndMDXStayVisible`, uses the
production-default `Bundle.main` lookup and passed in 1.942 s. The 8 s
readiness wait and the 2 s JavaScript deadline are unchanged.

No product code changed. The timeout was a property of the **hostless**
`PreviewKit-Package` test process, not of PreviewKit.

## Source

Tree `bd3dadcf5e0dd39e83896d6c463e285e8a0d6cb3`: `codex/ios-12-validation-wiring-20261015`
(#176, `69d499c`) merged with `codex/ios-07-ready-repair-20261015` (#173, `af389cb`), no conflicts.
Xcode 27.0 (27A5194q), iOS 27.0 simulator, iPhone 17
`00FE8F01-CC81-4A3D-B319-19DBBD84F4A4`, `-parallel-testing-enabled NO`.

## Root cause

`PreviewKit-Package` on iOS runs the test bundle inside the bare `xctest` process.
That process has no `UIApplication`; the log reports
`This process does not have a UIApplication object` and
`ProcessSuspension endowmentsForHandle: Process … is not running`.
In that process the **first `WKWebView` never finishes navigation**, whoever
creates it and whatever page it loads. Later web views mostly load in under 1 s,
but they still stall now and then for several seconds.
The historical failures were all recorded in this process:

- the real-bundle `bundle ready` timeout,
- the synthetic-page `InvalidTransition` failure,
- the three Export failures (below).

Earlier runs put the bundle case first, or near first, in the process. So it hit
the deterministic first-view stall, and the result read as a "real bundle" problem.

The following are **ruled out** by controlled probes (each probe is a
temporary test file, archived under `probes/`, never committed as a test):

| Suspect | Evidence |
|---|---|
| Bundle resource lookup (`Bundle.module` vs app bundle) | The real 64-file bundle copied to the container loads in 0.66–0.85 s in a plain `WKWebView` when that view is not first (v1, v3). |
| `loadFileURL` read-access scope | Same `loadFileURL(index, allowingReadAccessTo: dir)` call as the controller; finishes when not first (v3 `real`, `real-all`). |
| `asset:` scheme handler, `bridge` script handler, zero frame, transparent background | A view with all of the controller's configuration loads the real bundle in 0.66 s when not first (v2 `real-all`); each knob alone is fine (v2). |
| `PreviewController` itself | `PreviewController(previewIndexURL:)` on the real bundle becomes `isReady` in 0.736 s when it is the last test (v3). When it is the first, it is still `isLoading` after 20 s (v2). |
| Process age / cold start | Sleeping 25 s before creating the first view does not help: navigation starts at 2.45 s, commits at 5.27 s, never finishes within 20 s (v4). |
| `.nonPersistent()` data store | The first non-persistent view loads in 0.93 s (v5). In the same run, a later default-store view stalled 4.5 s with two 2 s JS timeouts. That intermittent stall is what the hostless Offline cases hit. |

In the app host, the first web view in the process is normal. In the `hosted`
probe run, `testBundledKitchenSinkAndMDXStayVisible` was the first test and
passed in 2.993 s; the full run above passed it in 1.942 s.

Why a non-app process breaks WebKit's first WebContent launch is platform
behavior, outside this repository. A likely factor is RunningBoard not tracking
`xctest` as an app (`endowmentsForHandle … not running`, `Client not entitled`
on terminate), but the probes do not prove it. The repo-level conclusion does
not depend on that detail: WebKit cases need an app host, which lane 12 provides.

## Probe results (hostless unless noted)

| Run | Order in process | Label | Ready (s) | Navigation events |
|---|---|---|---|---|
| v1 | after 2 controller cases | real / tiny | 0.853 / 0.662 | start→commit→finish |
| v1 hosted | after 2 controller cases | real / tiny | 1.161 / 0.673 | start→commit→finish |
| v2 | **controller first** | controller-real | never (20 s) | `isLoading=true` |
| v2 | later | real-all, tiny-zero, tiny-transparent, tiny-handlers | 0.58–0.66 | finish |
| v3 | **raw view first** | real-all | never (20 s) | none |
| v3 | last | controller-real | 0.736 | `readyState=complete` |
| v4 | first, after 25 s idle | real-all | never (20 s) | start 2.45, commit 5.27 |
| v5 | first / 2nd / 3rd / 4th | real-all / nonpersistent-1 / -2 / tiny | never / 0.930 / 0.889 / 4.520 | — |

## Export failures triage

The three failures from `review-20261013/preview-native` came from a hostless
`PreviewKit-Package` full-94 run:

| Case | Verdict |
|---|---|
| `ExportHTMLHostedTests/testMDXPlaceholdersExportWithoutComponentExecution` | Environment. It failed waiting for ready, the first-view stall. It passes app-hosted. |
| `ExportHTMLOfflineTests/testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument` | Environment. `didFinish` was missing, the intermittent hostless stall. It passes app-hosted. |
| `ExportHTMLOfflineTests/testOfflineReopenRendersEmbeddedResourcesWithoutNetwork` | Environment for the missing `didFinish`. The follow-on 60 s XCTest overrun was a real test-harness defect: an unbounded JS await. #173 (`2565695`) already fixed it with the throwing bounded waits. It passes app-hosted. |

Neither is a product bug. There is no remaining Export test defect after #173.

## Hostless `PreviewKit-Package` today

#173 made every iOS fixture use the packaged app bundle. The hostless scheme has
no such bundle, so its full run (`logs/hostless-full94.log.gz`, exit 65) now fails
those cases immediately at the `PreviewBundleFixture` `XCTUnwrap`, which names
`make ios-preview`. They no longer time out. `Scripts/ios/run-ios-tests.sh`
already refuses `IOS_SCHEME=PreviewKit-Package` as a gate. The full 94-case
PreviewKit suite on iOS is the `IOSPreview` app-hosted run.

## Mac

`swift test --package-path Packages/PreviewKit`: exit 0, **94 / 94 passed, 0 skipped** (`mac-previewkit.txt`).

## Files

- `probes/probe-v1.patch`, `probes/probe-v{2..5}.swift.txt`: the exact temporary probe sources for each run.
- `logs/*.log.gz`: complete xcodebuild output for each run (`gzip -n`). `ios-preview-full94.test.log.gz`, `admission.json` and `resources.json` come from the `make ios-preview` evidence directory.
- `SHA256SUMS`: hashes of the files above.
- The xcresult bundles are outside the repo:
  `side-session-notes/local_6bac6ea4-…/lane07-ready-root-cause-xcresults-20261021.tar.gz`
  (SHA-256 `fa4a75e01753ab0b7a9c6b0dd18869292b1ddeb9be6e1cb38d1510f62f774c5e`).

Commands (destination `platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4`):

```sh
make ios-preview IOS_DESTINATION="$DEST" IOS_OUTPUT_ROOT=<out>          # exit 0, 94/94
(cd Packages/PreviewKit && xcodebuild -scheme PreviewKit-Package -configuration Debug \
  -destination "$DEST" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -collect-test-diagnostics never test [-only-testing:PreviewKitTests/ZZReadyProbeTests/...])
xcodebuild -project Plainsong.xcodeproj -scheme IOSPreview -configuration Debug -destination "$DEST" \
  -parallel-testing-enabled NO -collect-test-diagnostics never test \
  -only-testing:IOSPreviewTests/ZZReadyProbeTests -only-testing:IOSPreviewTests/PreviewIOSHostedTests
```

## Not covered

Exact-head CI, iOS 26 runtime, physical devices, and the other owner-only M0 gates.
