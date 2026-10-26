# Lane 12 build-wiring proposal — iOS acceptance harness

> Current production launch smoke: [Files/Open contract, 2026-10-23](production-launch-smoke-20261023.md). This document preserves the earlier scaffold scope and results.

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Status: proposal only. This lane did not edit `project.yml`, the Makefile, `Scripts/ios/**`, or the iOS workflow. `PlainsongIOS` production composition stays unavailable.

## Diagnosis

PR #164 head `59f374ff9341289b91c0a4090b216dcf16510797` has no `IOSAcceptanceTests` target. `PlainsongIOSTests` is the C0 and module suite. `Scripts/ios/required-named-tests.txt` is explicitly not the product harness. `IOSProductionComposition` still publishes nil capabilities and the scaffold string. Real preview-bundle ready remains the recorded FAIL from review-20261013. M0 device gates stay open.

## Do not attach this to the existing scheme

Keep `make ios-test` and `Scripts/ios/required-named-tests.txt` on the current module runner. Add a separate scheme and required list so a 0-run or all-skip acceptance action cannot inherit the historical 294-case PASS.

## UI smoke target

| Field | Value |
|---|---|
| Target name | `IOSAcceptanceUITests` |
| Type | `bundle.ui-testing` |
| Platform / deployment | iOS 26.0 |
| Sources | `IOSAcceptanceTests/UI/**` |
| Resources | none in phase B |
| Host / TEST_HOST | `PlainsongIOS` (`app.plainsong.editor.ios`) |
| Test bundle id | `app.plainsong.editor.ios.acceptance-ui` |
| Info.plist | `GENERATE_INFOPLIST_FILE: YES` |
| Parallelization | off |

Suggested `project.yml` fragment:

```yaml
IOSAcceptanceUITests:
  type: bundle.ui-testing
  platform: iOS
  deploymentTarget: "26.0"
  sources:
    - path: IOSAcceptanceTests/UI
  dependencies:
    - target: PlainsongIOS
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: app.plainsong.editor.ios.acceptance-ui
      GENERATE_INFOPLIST_FILE: YES
      TEST_TARGET_NAME: PlainsongIOS
```

Scheme `IOSAcceptance`, test action only `IOSAcceptanceUITests`, `parallelizable: false`. Build `PlainsongIOS` for testing. Do not add the target to the `PlainsongIOS` scheme.

## Required hosted case

`docs/ios/evidence/validation/required-hosted-smoke.txt` names one case:

`IOSAcceptanceLaunchSmokeTests/testLaunchShowsUnavailableScaffold`

The case passes only when that exact scaffold string exists within 10 seconds. A pass means production composition is still unavailable. It does not close launch → edit → preview → save → reopen.

## Command lane 12 should wrap

Use the existing public lock in `Scripts/ios/ios-common.sh`. Do not add a second lock file. Suggested shape, owned by lane 12:

```sh
xcodebuild -project Plainsong.xcodeproj -scheme IOSAcceptance -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=<installed-uuid>' \
  -derivedDataPath "$IOS_OUTPUT_ROOT/dd/$HEAD12-acceptance-$STAMP" \
  -parallel-testing-enabled NO \
  -resultBundlePath "$EVIDENCE/Results.xcresult" \
  -collect-test-diagnostics on-failure \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test

xcrun xcresulttool get test-results tests --path "$EVIDENCE/Results.xcresult" --format json \
  > "$EVIDENCE/test-results.json"

python3 Scripts/ios/ios-test-results.py "$EVIDENCE/test-results.json" \
  --required docs/ios/evidence/validation/required-hosted-smoke.txt \
  --report "$EVIDENCE/acceptance-smoke-report.json" \
  --names "$EVIDENCE/acceptance-smoke-names.txt"
```

`ios-test-results.py` already fails closed on zero tests, all skips, failures, and missing required names. This lane ran that script against synthetic JSON only. No `IOSAcceptance` xcresult exists.

## Mac component package

`IOSAcceptanceTests/Package.swift` is the phase B executable suite. It is not an iOS app target. Lane 12 may later add a Makefile entry, but should not fold these cases into `make test` or `make ios-test` until the required list above is wired separately.

```sh
swift test --package-path IOSAcceptanceTests \
  --build-path <task-owned-build-path> \
  --scratch-path <task-owned-build-path>
```

Serialize that command with `/usr/bin/lockf -k` on `/private/tmp/plainsong-xcodebuild-test.lock`. There is no public runner for this package. Do not pass `--locked` or set `IOS_RUNNER_LOCK_*`.

Required names: `docs/ios/evidence/validation/required-component-tests.txt`.

## Resources

Pinned bytes: `IOSAcceptanceTests/Resources/acceptance-resource-manifest.txt`.

- 64 files under `App/Resources/preview/` must be an exact set. The component test hashes them and rejects extras, gaps, empty files, and symlinks.
- Read-only fixtures: `Fixtures/kitchen-sink.md`, `kitchen-sink.mdx`, `product-page.mdx`, `math.md`, `math-edge-cases.md`, `broken-frontmatter.md`, `mdx-syntax-error.mdx`, `perf-100kb.md`, `large-1mb.md`.
- Synthetic files owned here: `IOSAcceptanceTests/Resources/note.md`, `pixel.png`.

The UI target does not need those resources for the scaffold smoke. A later product target must copy the manifest paths into the test bundle and fail before timing if any hash differs. Do not point the preflight at a Mac bundle path.

## Lane 13 seam request

No DEBUG injection was added. `AcceptanceDebugSeam.isEnabled` is constantly false, including in Release. A future seam, if lane 13 accepts it, must:

- compile out of Release
- default off
- accept only a test-created directory that contains this lane's lease marker
- refuse user recents, security-scoped bookmarks, and parent grants
- leave source, UTF-16 selection, revision, and undo unchanged when the seam is off

Until that seam and real providers exist, do not feed the app a synthetic document and call the writing flow passed.
