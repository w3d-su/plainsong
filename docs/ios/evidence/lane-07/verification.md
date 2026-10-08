# Lane 07 — PreviewKit iOS verification

Date: 2026-10-09. Contract: **IOS-C0-v1**. No frozen declaration changed.

```text
branch: phase3-ios-preview-ios
base:   642cb212703220409874a2741c5adbfb8c80fe8a  (refs/tags/ios-c0-v1)
worktree: /private/tmp/plainsong-ios-preview-ios
PR target: phase3-ios-integration
```

The owner checkout `/Users/davis._.su/Documents/blogeditor` stayed on `phase3-native-macos-polish` and was not edited. This lane was not merged and was not force-pushed.

## What landed

- `PreviewController` stays the main-actor WebKit controller. AppKit color, layer, and `NSWorkspace.open` go through `PreviewPlatform`. iOS uses a clear `WKWebView` and `UIApplication.shared.open`.
- `MarkdownPreviewWebView` keeps the Mac `NSViewRepresentable` host and adds a UIKit host. `attach` reuses the controller's existing web view.
- `IOSPreviewControlling` is implemented on that controller. `render` takes the supplied `PreviewAssetAccessContext` only. A nil context does not promote the file parent into an asset root and reports `IOSPreviewEvent.failed(.unavailable)` once per nil installation.
- Asset loads go through an injected `PreviewAssetReading`. Mac installs `DirectPreviewAssetReader` (the existing `AssetURLPolicy.loadAsset` path). iOS installs nothing until `installAssetReader(_:)`, and then fails closed. Production composition is not wired.
- `AssetReadCompletionFence` (`LANE07_COMPLETION_FENCE`) re-checks the plainsong-root token, grant identity, access generation, stop, and invalidation before `didReceive` / `didFinish`. The coordinated URL is re-resolved, including a dangling symlink, and the MIME allowlist plus 10 MiB cap are applied to the returned bytes.

`BridgeMessage.swift`, `ExportBridgeMessages.swift`, `PreviewAssetReading.swift`, `PreviewContracts.swift`, `PreviewContractExports.swift`, `preview-src/**`, and `App/Resources/preview/**` are unchanged. Protocol version stays 8.

## Commands and results

Mac, final tree, `swift test --package-path Packages/PreviewKit`:

```text
Executed 91 tests, with 0 failures (0 unexpected)
```

That includes the existing export bridge, resource, lifecycle, and offline suites, plus the new fence, identity, and hosted tests. The kitchen-sink / MDX fixture render runs on Mac.

iOS 27.0 simulator, iPhone 17, `xcodebuild test -scheme PreviewKit-Package`:

- `PreviewAssetFenceTests`: 12 tests, 0 failures. Log `/tmp/lane07-ios2.log` (before the iOS-only skip; fence sources were unchanged after that run).
- `PreviewIdentityTests`: 6 tests, 0 failures.
- `PreviewIOSHostedTests`: hosted ready / render / checkbox passed. `testBundledKitchenSinkAndMDXStayVisible` skipped. Log `/tmp/lane07-ios4.log`, `TEST SUCCEEDED`, exit 0.

## Excluded on iOS

`testBundledKitchenSinkAndMDXStayVisible` throws `XCTSkip` on iOS. The simulator `WKWebView` did not become ready for `loadFileURL` of the Mac repository preview bundle (the WebContent process did not deliver `ready`). Mac `swift test` runs that fixture. The temp-page test covers the iOS web-view lifecycle, render identity, and checkbox post.

Export HTML tests are not an iOS product surface. They still compile for the iOS package test target and were executed on Mac. They were not part of the iOS `only-testing` list.

## Negative probe

`AssetReadCompletionFence.permission` was temporarily forced to `acceptsDelivery == true` (`let current = true`). `testBlockedReadFromRootADoesNotDeliverIntoRootB` then failed:

```text
XCTAssertEqual failed: ("1") is not equal to ("0")
```

The finished read was delivered after the root switch. The condition was restored. The same test passed again (0.560s, then again inside the final 91).

## Open gates

- Lane 06 real `PreviewAssetReading` provider. This lane does not import WorkspaceKitIOS.
- Lane 01 M0 device gates: iCloud / Files asset access, real-device WebKit, background reads.
- Lane 11 performance: 100 KB render < 100 ms and the separate 150 ms debounce.
- Manual: iPhone rotation, iPad side-by-side layout toggle, external-link handoff, single-file folder-access prompt.
- No production `AppIOS` composition and no claim that simulator image loads are iCloud grants.

## For the integrator

- Call `PreviewController.installAssetReader(_:)` with lane 06's reader. Do not construct a `PreviewKit` file reader inside `WorkspaceKitIOS`.
- Keep iOS sibling reads disabled until that reader exists. Nil `assetAccess` is the file-only grant.
- Lane 12 still owns `project.yml`. C0's app target depends on `PreviewKitContracts`. Switching the app to the full PreviewKit product is a 12/13 manifest change, not this PR.
- No Decision Log edit. The platform adapter and reader injection are the assigned lane scope.
