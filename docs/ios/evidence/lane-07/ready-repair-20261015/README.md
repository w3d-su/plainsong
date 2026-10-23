# Lane 07 ready-load evidence — 2026-10-15

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../../README.md); run historical local-path commands from that restored checkout.

The hosted preview ready gate remains **FAILED**. Commit `9ae2b78` adds this note only. It does not change product or test code. Head `59f374ff9341289b91c0a4090b216dcf16510797` is the review tree these notes started from. Branch `codex/ios-07-ready-repair-20261015`. The owner checkout was not modified.

## Open gate

`PreviewIOSHostedTests/testBundledKitchenSinkAndMDXStayVisible` is still open. This lane did not produce a passing first-controller run of the real bundle, and it did not run the kitchen-sink table, code, math, Mermaid, or MDX DOM assertions to a pass. The full iOS 94-case `PreviewKit-Package` gate was not run and is not closed. The three previously recorded export failures were not re-executed.

A later controller, created after another load has already consumed the 8-second wait, is not a first-load pass. Cold-start synthetic failure and real-bundle failure stay separate observations. `UIApplication` or test-host differences are not a demonstrated cause.

A later fix has to make the first controller ready in a real app-hosted, production-equivalent process. It must keep the 8-second throwing wait and the 2-second JavaScript callback deadline. It must not pass by warming a second load, by deleting assertions, or by lengthening either deadline. A test host or scheme change belongs to lanes 12 and 13.

## Unmodified baseline

This lane did not archive an unmodified execution of `59f374f`. Every simulator log below was produced from a worktree that had already been edited and was later restored with `git checkout`. The restored tree has no `PLAINSONG_READY` symbol. The committed source therefore cannot rebuild those logs.

The historical candidate note in `docs/ios/evidence/review-20261013/preview-native/README.md` is a different commit (`3fc31d4`). It is not an unmodified run of this head.

## Modified diagnostics are observations only

No per-run patch, instrumentation helper, or input manifest was kept. A baseline SHA plus a log hash does not prove that a run changed only the variable described in the previous revision of this note. Those descriptions are withdrawn. The logs remain local observations. They are not a causal attribution.

Each log begins with the `xcodebuild` command that the driver wrote. Scheme `PreviewKit-Package`, destination `platform=iOS Simulator,id=A24A1CB9-2861-4AA4-A79F-E53F768950D8`, derived data `/private/tmp/plainsong-ios-07-ready-diag1-dd`, `-parallel-testing-enabled NO`, `CODE_SIGNING_ALLOWED=NO`. The selection and the driver exit are what the log file records. Source identity for that command was not archived.

| Run | Selection recorded in the log | Driver exit | Result bundle | Patch retained |
| --- | --- | --- | --- | --- |
| diag1 | `PreviewIOSHostedTests` | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag2 | synthetic case only | `DIAG_EXIT -15`, banner `** BUILD INTERRUPTED **` | incomplete; see below | no |
| diag3 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag4 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag5 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag6 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag7 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag8 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag9 | synthetic case only | `DIAG_EXIT 0`, banner `** TEST SUCCEEDED **` | `Info.plist` present | no |
| diag10 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present; log has compile errors and no `Test Case` | no |
| diag11 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |
| diag12 | synthetic case only | `DIAG_EXIT 65`, banner `** TEST FAILED **` | `Info.plist` present | no |

diag9's success banner is not a first-load pass. Its source patch was not retained, so the log cannot show which test edits produced that banner.

diag11's driver also logged `Failure collecting diagnostics from simulator` after a 600-second `simctl diagnose` wait. That collection delay is separate from the test banner.

## diag2 is three separate facts

1. **Log observation of a named failure.** Before the driver stopped, the log printed `Test Case '-[PreviewKitTests.PreviewIOSHostedTests testHostedPageBecomesReadyAndRendersTheLatestDocument]' failed (15.254 seconds).` The caught string in that same log is `InvalidTransition`. The source that printed it was not retained.
2. **Driver interruption.** The same log then prints `** BUILD INTERRUPTED **` and `DIAG_EXIT -15`. Exit `-15` is the driver's record that `xcodebuild` was signaled. It is not a completed test status.
3. **Incomplete result bundle.** `/private/tmp/plainsong-ios-07-ready-diag2.xcresult` contains `Data/` and `Staging/` and has no `Info.plist`. It is not a parseable xcresult. Do not cite it as the result of the named failure.

## Log hashes

These hashes identify the observation files. They do not identify the source that was compiled.

| File | SHA-256 |
| --- | --- |
| `/private/tmp/plainsong-ios-07-ready-diag1.log` | `ce526ff600ddbba49dbb452277cd9238a39c8843ffe3b544c9a2be70864a634e` |
| `/private/tmp/plainsong-ios-07-ready-diag2.log` | `f22c5bbbe2eae8746277b4c84a7af4e7e98a090f0f873c71950b287919b652c2` |
| `/private/tmp/plainsong-ios-07-ready-diag3.log` | `22626461ef26f935ac60f144e4091a03437583b8903d7ddd9b69409143c99793` |
| `/private/tmp/plainsong-ios-07-ready-diag4.log` | `5d400a3607a17b43e34b8bf5179871966fe36de965b4ffe87ee88bb8cedf97a1` |
| `/private/tmp/plainsong-ios-07-ready-diag5.log` | `4a4e35af0905ce6abd67190c3ad489c6d861e5ba03b477d7ce45b9744843ab48` |
| `/private/tmp/plainsong-ios-07-ready-diag6.log` | `fde16cd9917da049b2a937dea39a413711d34e1bc0e823622e3accdb9f2bf799` |
| `/private/tmp/plainsong-ios-07-ready-diag7.log` | `f629c68dd2b901e0a474ef0b65569cda3713453455f33fa470e603f765aa9d93` |
| `/private/tmp/plainsong-ios-07-ready-diag8.log` | `94abb42647d8261ca2514c2b2005558eb499033a38e4ee385966c9e55b137a47` |
| `/private/tmp/plainsong-ios-07-ready-diag9.log` | `30faaacd291ac00ccc5b08ac1a7074aa1eddb945018e6873d04278095131b474` |
| `/private/tmp/plainsong-ios-07-ready-diag10.log` | `f0d29c0f415c2fba18f1f0cb8c03a309faf1c37b343554621ffa417e6a88ef28` |
| `/private/tmp/plainsong-ios-07-ready-diag11.log` | `1759795a571b634e563bb2e9021a225593bf3323917c2736c211e4c200cf6481` |
| `/private/tmp/plainsong-ios-07-ready-diag12.log` | `5ed11231eb93530a056a74257bd9e354e71d3a24344cc6b0dd74a9d8b4fce43a` |

## What a later diagnostic must archive before it is interpreted

For each run, under this directory, before any cause is claimed:

- A patch against `59f374f`, or against the previous archived patch, plus the SHA-256 of every changed source file.
- The instrumentation helper, if the run emits probe lines.
- The exact command and the driver exit status.
- Whether the xcresult has `Info.plist`. An interrupted driver and a missing `Info.plist` stay separate from a named test failure.

## Not run

- Mac `swift test --package-path Packages/PreviewKit`.
- Full iOS `PreviewKit-Package`.
- Exact-head CI, device, Files/iCloud, background save, owner-signed install, and performance. M0 device IME and Undo stay open.
