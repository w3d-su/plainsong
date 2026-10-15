# Lane 12 — acceptance scheme wiring, 2026-10-15

Base is PR #164 head `fdbcd44444f958589cb1e662d67ce3015e5e9f30` on `codex/ios-review-fixes-20261013`. The prompt's earlier pin `59f374ff` is the parent of that head; the harness from PR #171 is already in `fdbcd444`. This lane did not reset either branch.

Worktree: `/private/tmp/plainsong-ios-12-validation-wiring`. Branch: `codex/ios-12-validation-wiring-20261015`.

The runs below were dirty at `fdbcd444` because these wiring files were uncommitted. Both runs share source fingerprint `6ab05e5271444fde94da8952002c98743e4e3c67734e283b41d21a4f0e077cb8` and the same `source.json` SHA-256 `fa478b817d5343692a806e1570aece1fc2a27d84848b6f62caf517425b5a3547`. That fingerprint covers `project.yml`, `Makefile`, `Scripts/ios/`, `IOSAcceptanceTests/`, `AppIOS/`, `AppIOSTests/`, `App/Resources/preview/`, and `Packages/`. Evidence markdown is not part of it. Commit `dc9d02d8e03928ba56c3daecfde66d479cce3f0e` contains those wiring bytes. All 679 fingerprinted files match that commit; only the receipt's recorded `source_sha` and dirty bit still name the parent.

## What this wires

`IOSAcceptanceUITests` is an iOS 26 UI-testing bundle hosted by `PlainsongIOS`. Scheme `IOSAcceptance` tests only that bundle, with parallelization off. It is not a test action of scheme `PlainsongIOS`.

`make ios-test` still uses `Scripts/ios/required-named-tests.txt`. `make ios-acceptance` uses `docs/ios/evidence/validation/required-hosted-smoke.txt`. `make ios-acceptance-components` runs the Mac package and checks `docs/ios/evidence/validation/required-component-tests.txt`. Neither target is part of `make test` or `make ios-build`.

Admission, after a successful simulator build-for-testing, requires one xctestrun for the requested scheme, an enabled plan, and a Mach-O image inside each enabled `.xctest`. Format 2 empty `TestConfigurations` and format 1 plans with no test bundle both fail. `.swiftmodule` and `.a` products are ignored and are not compiled tests. The resource manifest must be non-empty, and `App/Resources/preview` must match the built bundle byte for byte. The source manifest is captured before the build and verified after it. XCResult names come from `xcresulttool`; zero runs, all skips, failures, and missing required names fail. The canonical lock default wait is 45 seconds and exits 75 only when the payload never started. A payload exit is returned as itself.

## Hosted smoke

Command:

```sh
IOS_DESTINATION='platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-12-validation-wiring-output \
  make ios-acceptance
```

Xcode 27.0 (`27A5194q`), iphoneos/iphonesimulator SDK 27.0, 12 available iOS 26+ simulators. Runner exit 0. `IOSAcceptanceLaunchSmokeTests/testLaunchShowsUnavailableScaffold` Passed. Executed 1, passed 1, skipped 0, failed 0. Resource preflight found 4 paths and compared 64 preview files with 0 mismatches. Admission compiled 1 test image (`IOSAcceptanceUITests`, 65416 bytes) and ignored swiftmodules.

This pass means the unavailable scaffold string is on screen. It does not close launch, edit, preview, save, Files, IME, or performance.

Evidence directory: `/private/tmp/plainsong-ios-12-validation-wiring-output/evidence/fdbcd44444f9-acceptance-20261016-014322-63539`

| File | SHA-256 |
|---|---|
| `test-gate.json` | `7b83016c772f04e44e0d0f31b805a50c45e2c5567ae49163f05f5c4901ecb933` |
| `admission.json` | `f31a169f932c27474615d4578f00f7c8dd5aa0670a8dfdb797bb55e84bb60c91` |
| `test-results.json` | `a07f494fa28d16ac6c65c0a58437e8c8f49be97f34cdd093514de52478b9f630` |
| `resources.json` | `413eb54d73855a2e364694adfe7e06e1063668e4ece52bbfae0f7e3e8c4c4111` |
| `test.json` | `aa2eba2f0811dddf9d941caebe5047cc5eaadcefa3503075b3d9cace548b82c7` |
| `named-tests.txt` | `cbd1d87a3e32f82ac4fdbc62330ec44ab403d567e0d65f46baaf157cb7ebfa36` |
| `source.json` | `fa478b817d5343692a806e1570aece1fc2a27d84848b6f62caf517425b5a3547` |

The first build-for-testing of this scheme, `fdbcd44444f9-acceptance-20261016-013621-58970`, exited 0 and produced `IOSAcceptance_iphonesimulator27.0-arm64.xctestrun`. Admission then exited 65 with `expected one enabled IOSAcceptance xctestrun, found 0` because that Xcode writes format 1 plans: `SchemeName` is under `__xctestrun_metadata__`, and targets are top-level keys. The parser now accepts that shape and still rejects an empty format 2 `TestConfigurations` array. The same products then admitted 1 image. The failed report remains in that directory's `admission.json`.

## Mac component package

`make ios-acceptance-components` at `fdbcd44444f9-components-20261016-014541-65416`: XCTest 29 executed, 29 passed, 0 skipped, 0 failed. Swift Testing reported 0 tests; that footer is not the result. Exit 0. Result format is `swift-test-xctest-log`, not an XCResult.

| File | SHA-256 |
|---|---|
| `component-gate.json` | `a7ba5fedffd4a96f8687e68ba357cb5474bd9d0a13578cda67f6347dd6a22bd7` |
| `swift-test.log` | `4cbd403a6d1050c388f8e3f6c89e702c7c33eaece6bab0af41a436eb31e361eb` |
| `components.json` | `11233496d8e52f2b76095e482219a562244073488d48b3828e839a2283454201` |
| `named-tests.txt` | `7d58b860fd643b50c8a5ac61ccc830cf82e869373a67c3e85bd1ae823ff926e6` |
| `source.json` | `fa478b817d5343692a806e1570aece1fc2a27d84848b6f62caf517425b5a3547` |

## Module plan and tooling

`PlainsongIOS` build-for-testing at `fdbcd44444f9-module-bft-20261016-013653-59806` was not executed as tests. After the format 1 parser fix, admission of those products reported `tests_compiled` true and 6 images: `EditorKitIOSTests`, `MarkdownCoreTests`, `PlainsongIOSTests`, `SyntaxKitTests`, `WorkspaceCoreTests`, `WorkspaceKitIOSTests`. This is not a rerun of the historical 294-case result.

`make test-ios-tooling` equivalent, 35 tests, passed when the canonical lock was free (`Ran 34 tests` before the format 1 fixture, then the fixture file's 10 tests, and a later 25-test `test_runner_evidence.py` run collided with another lane). The collision exited 75 or timed out while waiting; those runs are not functional failures of the payload. A free-lock run passed `testLegitimateNestedOperationUsesOneCanonicalLock`, `testPayloadFailureStaysDistinctFromAdmission` (65 and 75), and `testBusyLockAdmissionExits75WithoutRunningPayload`.

## Not claimed

- No Release archive and no IPA. Lane 13 has not published an integration head for this wiring, so no old archive was repacked.
- Hosted `ios.yml` is not on `main` (`GET /.github/workflows/ios.yml?ref=main` is 404) and is not in `gh workflow list`. No hosted run was dispatched. There is no hosted PASS.
- No preview entry. `xcodebuild -list` shows `PreviewKit` and `PreviewKitContracts`, not `PreviewKit-Package`. `IOS_SCHEME=PreviewKit` exits 64 before taking the lock. Lane 07 still owns the required ready cases; this lane did not add a selector that omits the known ready failure.
- M0 device, Files/iCloud, IME/Undo, background save, and owner re-sign remain open. Production composition stays the unavailable scaffold.
- `make test` / `make ios-test` do not include `IOSAcceptanceTests` or the iOS-only packages.

## Seams

- Lane 13: the acceptance scheme and the separate make targets need a Decision Log row. No DEBUG seam was added. `AcceptanceDebugSeam` stays off.
- Lane 07: a preview runner, if added later, must use scheme `PreviewKit-Package` and lane 07's full required list, including the current ready failure.
- Lane 11: test sources were not edited. The hosted required name is the one case in `required-hosted-smoke.txt`.
