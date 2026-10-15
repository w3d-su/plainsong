# Lane 07 ready-load diagnosis — 2026-10-15

The hosted preview ready gate remains **FAILED**. No product code changed. This record is the controlled timeline for the first `loadFileURL` on review head `59f374ff9341289b91c0a4090b216dcf16510797`.

Scheme `PreviewKit-Package`, destination `platform=iOS Simulator,id=A24A1CB9-2861-4AA4-A79F-E53F768950D8` (iOS 27.0, `iPhone18,3`), `-parallel-testing-enabled NO`, `CODE_SIGNING_ALLOWED=NO`. The 8-second throwing wait and the 2-second JavaScript callback deadline were not lengthened. Worktree: `/private/tmp/plainsong-ios-07-ready-repair-20261015`, branch `codex/ios-07-ready-repair-20261015`. The owner checkout was not modified.

## Still failing

`PreviewIOSHostedTests/testBundledKitchenSinkAndMDXStayVisible` still throws `Timed out waiting for bundle ready` from the unchanged 8-second wait when that case is the first WebKit load in the process. The synthetic case fails the same way when it is the first load. Kitchen-sink table, code, math, Mermaid, and MDX DOM assertions have not passed on this head.

A later page in the same process can become ready. That does not make the first page ready.

## What the timelines show

Every first `loadFileURL` followed the same sequence:

1. The read grant is the index file's parent directory (`hasDirectoryPath=true`). Copied bundle hashes matched the repo for the real page (`index.html` `0d13d50cad21da80a8642f8e45919aa79fbbd9b2ded1b1184ac907e6e4ca3547`, `bundle.js` `1e7784e4b13886ccf23c75a36403fd1b505a68f09f2536de7bd14ec2d63b2917`, `bundle.css` `94d264a5a431d0c184d83c5943d6f3179ed178e74e1330396694e77839124294`).
2. `decidePolicy` allows the exact index URL (`WKNavigationActionPolicy.allow`, raw value 1) after WebContent has launched.
3. `didStart`, `didCommit`, `didFinish`, and `didFail` do not arrive. A 20-second observation of an otherwise unmodified first load also had no `didStart`.
4. The document stays unreadable or, once a later web view can run script, remains `about:blank`.

The xctest process logs `This process does not have a UIApplication object`. Calling `UIApplication.shared` before the load returned a nil delegate and did not remove that log line or start navigation. ExtensionKit "Client not entitled" lines appear when a web process is torn down. They were not treated as the cause.

| Run | What changed | Result |
| --- | --- | --- |
| diag1 | Real bundle, then synthetic page, same process | Bundle failed, 14.510s, no `didStart`. Synthetic passed, 1.870s: `didStart`, `didFinish`, protocol `Optional(8)`, `isReady`. |
| diag2 | Synthetic page only, fresh process | Failed. Policy allow, no `didStart`. |
| diag3 | Allow reply deferred to the next turn | Failed. `decision-delivered` after WebContent launch, still no `didStart`. |
| diag4 | `stopLoading` and a second `loadFileURL` on the same web view | Failed. The second call produced no navigation callbacks. |
| diag5 | Unmodified first load observed for 20 seconds | Failed at 20.882s. Still no `didStart`. |
| diag6 | Sacrificial file load, then the visible web view after that allow | Both allows logged. Neither reached `didStart`. |
| diag7 / diag8 | Second controller immediately after the first allow, held or released | Second allow logged. No `didStart`. |
| diag9 | First controller kept for the full 8 seconds, released, then a new controller | **Passed, 10.392s.** The 8-second clock covered only the second controller. Its load reached `didStart`, `didCommit`, `didFinish`, protocol 8, and `isReady` about 2 seconds after it was created. Wall time from the first load was about 10.4 seconds. |
| diag11 | Controller replaces its web view 2 seconds after the first allow | Failed, 10.161s. Replacement process became unresponsive. DOM was `about:blank` with no bridge. |
| diag12 | `UIApplication.shared` before the first load | Failed, 12.304s. Same policy-allow stall. Runtime still reported no `UIApplication`. |

diag1's passing synthetic case is the same shape as diag9: it ran only after another web view had already lived through a full stuck load. It is not evidence that a cold first load succeeds.

## Rejected changes

These were tried in the worktree and reverted. None made the first controller ready within 8 seconds:

- Delivering the allow decision on the next main-actor turn.
- Reloading the same web view.
- Starting a sacrificial file load and then loading the visible web view.
- Replacing the web view two seconds after the allow.
- Touching `UIApplication.shared` from the test.

The 8-second wait was not increased. Root, token, and reader fences were not edited.

## Logs

Simulator logs and xcresults are local scratch, not committed. SHA-256 of each log:

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
| `/private/tmp/plainsong-ios-07-ready-diag11.log` | `1759795a571b634e563bb2e9021a225593bf3323917c2736c211e4c200cf6481` |
| `/private/tmp/plainsong-ios-07-ready-diag12.log` | `5ed11231eb93530a056a74257bd9e354e71d3a24344cc6b0dd74a9d8b4fce43a` |

xcresults: `/private/tmp/plainsong-ios-07-ready-diag1.xcresult` through `diag12.xcresult`, excluding the compile-only diag10 attempt. Derived data: `/private/tmp/plainsong-ios-07-ready-diag1-dd`. xctest image: `.../Build/Products/Debug-iphonesimulator/PreviewKitTests.xctest/PreviewKitTests`.

diag11's failure collection waited on `simctl diagnose` until the 600-second simulator timeout (`Failure collecting diagnostics from simulator`). Later runs passed `-collect-test-diagnostics never`. diag12's test session finished in 27.449 seconds.

## Not run

- Mac `swift test --package-path Packages/PreviewKit`. No product delta remains, so this was not re-run.
- Full `PreviewKit-Package` iOS suite. The three previously recorded export failures were not re-executed. The full 94-case gate is not green.
- Exact-head CI, device, Files/iCloud, background save, owner-signed install, and performance. Those stay open. M0 device IME and Undo stay open.

## Next measurement

A fix has to make the **first** controller's file load reach `didStart` and `isReady` inside the existing 8-second wait. Creating another controller after one stuck load has already consumed 8 seconds does not meet that gate. The production app has a `UIApplication`; this package test host does not. That difference is still only a hypothesis, because constructing `UIApplication.shared` inside the test did not start the navigation.
