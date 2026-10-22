# Lane 06 receipt — Workspace access

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Status: **module-ready**. Lane 13 can inject the production factory. App composition stays unavailable. M0 Files, iCloud, device, exact-head CI, and performance gates stay open.

| Field | Value |
|---|---|
| Branch | `codex/ios-06-workspace-access-20261015` |
| Base | `codex/ios-review-fixes-20261013` / `59f374ff9341289b91c0a4090b216dcf16510797` |
| Head | This commit on `codex/ios-06-workspace-access-20261015` |
| Frozen APIs | Unchanged. `ios-c0-v1` (`642cb212703220409874a2741c5adbfb8c80fe8a`) was not the implementation parent |
| Package manifest | `Packages/WorkspaceKitIOS/Package.swift` was not edited. SwiftPM picks up the new `Access/` and `Workspace/` sources |
| Generated resolve file | `Packages/WorkspaceKitIOS/Package.resolved` appeared during the simulator run and is left untracked |

## What lane 13 injects

```swift
let access = IOSWorkspaceAccessFactory.makeProduction()
```

`makeProduction(recents:recentKey:)` defaults to `UserDefaults.standard` and the key `Plainsong.IOSRecentWorkspaceGrants`. It returns one `IOSWorkspaceAccessService` that conforms to:

- `IOSWorkspaceAccessProviding`
- `IOSCoordinatedFileAccess`
- `IOSWorkspaceAssetWriting`
- `PreviewAssetReading`
- `PreviewAssetAccessChecking`

Lane 05 keeps owning document bytes and calls `rebaseSavedText(to:)` on a successful save. This service emits `IOSWorkspaceEvent` values. It does not subscribe the document store, change a session URL, or nest `NSFileCoordinator` around UIDocument. Lane 13 wires `observe` into lane 05 after M0.

## Lifetimes

`open` and `restore` start one security scope and hold it for the life of that grant. Each `open` mints a new `IOSWorkspaceIdentity` and root token. Generation starts at 1. Leases and in-flight operations are extra holds. `release()` drops one consumer. The scope stays up while any consumer or operation remains, including after `invalidate`.

`invalidate` marks the grant revoked, bumps the generation, clears the latest request id, and publishes `.invalidated`. `stop` runs only when the grant is revoked, idle, and the scope was actually started. A lease acquired after revoke fails with `grantChanged`. `currentGrant` returns nil once the scope has stopped. A false `startAccessingSecurityScopedResource` is not success, and the parent URL is never started.

A single-file grant authorizes that file alone. Directory listing is metadata-only (`NSFileCoordinator.ReadingWithoutChanges` and `immediatelyAvailableMetadataOnly`). Each listed directory is the grant root joined with that directory's root-relative path. A seen set of raw UTF-8 spellings keeps canonical-equal names distinct and stops one path from being queued twice. Symlink directories are not descended. Drawing the tree does not download file bodies. An offline refresh publishes `.unavailable(reason: .offline)` and leaves `latestSnapshot` in place.

Inside each coordinated accessor, read, list, create, and delete resolve the real path and require it to stay inside the grant root. An ancestor symlink that reaches another root is `.outsideGrant` for read, write, and delete. Public snapshot entries and `read` results use the logical grant location: the original root joined with the root-relative path. `authorize` still requires that logical URL byte for byte. The proved real path stays internal, on `IOSWorkspaceFileItem.provedURL` and on the read payload's coordinated URL. A location built from the proved path is `.outsideGrant`. Literal path comparison stays the authorize check. It is the single-file scope check, and it is separate from the ancestry proof.

The caller deadline is separate from coordinator drain. A read or list that hits the deadline returns `.coordinationFailed`. The coordinator is cancelled, and a later port result cannot replace that caller failure. The scope stays up until the port returns and `finish` runs. `NSUserCancelledError` from a coordinator cancel still maps to `.unavailable`. The deadline failure itself is `.coordinationFailed`.

A create does not use that discardable race. When the deadline or cancellation wins, the caller receives a retained receipt while the create's operation ticket stays held. The late result is not discarded. After the port returns, a proved identity is removed and a nil identity keeps the file. The ticket stays held through that remove. A late `IOSFilePersistedButUnreadable` follows the same rule. The abandoned create is not published. `CancellationError` is still used only when no operation-owned leaf remains.

Stage metadata, validate, rollback remove, unpublished reclaim, and adopt metadata bound the caller and still drain the port. Metadata and remove each hold a lease or operation ticket until that call's own port returns. A rollback that has already returned a receipt does not release the remove's hold. Standalone validate and rollback keep the scope up across an invalidate until their parked port returns. These paths were checked with a scripted port that parks inside the accessor. This run did not observe a live Files provider hang.

Production bookmarks use `options: []` on create. Resolve uses `.withoutUI`, `.withoutMounting`, and `.withoutImplicitStartAccessing`, then an explicit `startAccessingSecurityScopedResource`. `NSURLBookmarkCreationWithSecurityScope` and `NSURLBookmarkResolutionWithSecurityScope` are unavailable on iOS. The production identity port returns nil until a File Provider port supplies opaque bytes. URL, inode, and `NSURLDocumentIdentifierKey` are not provider identity. Recents keep the last 10 successful opens, dedupe only when a real provider identity exists, and store bookmark bytes off `IOSRecentWorkspaceItem`. `removeRecent` does not delete the file.

External presenter callbacks enqueue `resourceChanged` or `unavailable` and return. They do not implement `savePresentedItemChanges` and do not coordinate. The callback keeps the workspace identity, generation, and root token from the registration that started it. Pending notices coalesce on that tuple plus the relative path. `report` delivers only to the grant that still has the same identity, generation, and root token. An offline notice does not mark any other root offline. A callback that arrives after `invalidate` keeps the old generation and is dropped.

The preview reader holds its lease until the coordinated read finishes, checks the access context again, then releases the lease on the main actor. It returns the original `PreviewAssetAccessContext`. Root, type, size, symlink, and token policy stay with lane 07. `isCurrent` checks root URL, root token, grant identity, generation, and that the grant is still running. It does not grant access.

The image writer requires `grant.scope == .directory` before it creates anything. It returns `IOSStagedImageAsset` only after the leaf exists. Commit and rollback touch that operation's leaf. Rollback deletes the leaf only inside one `removeIfOwned` coordination, and only when that coordination proves the provider identity still matches. A nil identity, a same-size replacement, or a file owned by another operation stays on disk with a receipt. The byte count is not ownership. If `createFile` has stored bytes and the grant cannot be published, the service keeps that leaf on the operation from that moment. It deletes the leaf only when the same protected remove proves ownership. Otherwise `stage` throws `.retained` and the file stays with a receipt. When the create's own deadline or cancellation wins, the caller receives that receipt before the port returns, and the operation ticket stays until the late cleanup drains. `CancellationError` is used only when no operation-owned leaf remains. Markdown extensions are refused. A missing folder grant surfaces `requiresDirectoryGrant`.

## Typed failures

Callers rethrow `CancellationError` before `IOSWorkspaceFailureMapping`. Cocoa not-found, permission, and already-exists codes map to `.notFound`, `.permissionDenied`, and `.alreadyExists`. `NSUserCancelledError` maps to `.unavailable`. Ubiquitous codes `NSUbiquitousFileUnavailableError` (4353), `NSUbiquitousFileNotUploadedDueToQuotaError` (4354), `NSUbiquitousFileUbiquityServerNotAvailable` (4355), and the range 4352...4607 map to `.offline`. Other errors map to `.coordinationFailed`.

`stage` throws `IOSAssetStageFailure` or `CancellationError`. `validate` throws `IOSWorkspaceFailure` or `CancellationError`. `commit` and `rollback` return `.committed` / `.removed` or `.retained`. Preview failures map `grantChanged` to `accessChanged`, `outsideGrant` and `invalidPath` to `outsideRoot`, and `tooLarge` / `unsupportedType` to the matching preview cases. Remaining workspace failures become `providerFailed`.

A thrown coordinated read stays a failure. An empty file that the provider successfully returns is a successful empty `Data`.

## Provider matrix

| Provider | Exercised by | Result on this head |
|---|---|---|
| Scripted scope, bookmark, identity, and file ports | Lease, bookmark, snapshot, asset, and preview tests below | Simulator pass |
| Local temp-file bookmark (`IOSSystemAccessPorts`, no security-scope bookmark option) | `testLocalBookmarkRoundTripLeavesProviderIdentityUnknown` | Simulator pass. Provider identity is nil. This is a local bookmark round trip |
| `NSFileCoordinator` production file port | Two-level temp-directory listing, ancestor-symlink refusal, nil-identity remove, an alias-root list and repeat-read, and a blocking-presenter deadline. Race tests still use the scripted port | Files and iCloud in-place use is open |
| File Provider opaque identity | Production port returns nil | Open until a port supplies provider bytes |
| iCloud placeholder / not downloaded | Scripted offline refresh keeps the previous tree. Ubiquitous error codes are mapped in source | Device iCloud is open |
| Security-scoped bookmark options | Unavailable on the iOS SDK. Production uses a plain bookmark plus `startAccessingSecurityScopedResource` | Device Files grant lifetime is open |

Copy-in sandbox directories and the scripted provider are component evidence. They do not accept in-place Files or iCloud behavior.

## Simulator module run

### This head

Command, from `Packages/WorkspaceKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme WorkspaceKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-06-r4-dd \
  -resultBundlePath /tmp/plainsong-ios-06-r4-results.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

| Item | Value |
|---|---|
| When | 2026-10-16 01:38:26 +0800 through 01:38:39 +0800 |
| Destination | iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0 (`24A5355p`), arm64 simulator |
| Xcode | 27.0 build `27A5194q` at `/Applications/Xcode-beta.app` |
| Compile SDK | iPhoneSimulator 27.0, target `arm64-apple-ios26.0-simulator` |
| Result | `TEST SUCCEEDED`. `totalTestCount` 107, `passedTests` 107, `failedTests` 0, `skippedTests` 0 |
| Log | `/tmp/plainsong-ios-06-r4-test.log` SHA-256 `e025cb7a37185ea8cdc39980572dd8db88eed6fe419165e2960043067f1df548` |
| Summary | `/tmp/plainsong-ios-06-r4-summary.json` SHA-256 `c861b6593355d070703f7f3fa937d34736db8e1a372ce78bd2360913f266d911` |
| XCResult content hash | `/tmp/plainsong-ios-06-r4-results.xcresult` SHA-256 of sorted relative path, a NUL byte, then file bytes `4d579323ee9c77f946994aaba685b44c329c11bc53d5eec4981e19184c97560e` (254 files) |

The 107 cases are the previous 104 plus these 3:

- `IOSWorkspaceWriteDeadlineTests/testDeadlineReturnsAReceiptWhileCreateStaysParked`
- `IOSWorkspaceWriteDeadlineTests/testLateCreateKeepsScopeWhileRemoveStaysParked`
- `IOSWorkspaceEffectDeadlineTests/testStageMetadataDeadlineKeepsScopeUntilTheProvedRemoveDrains`

`waitUntil` fails the test when its one-second budget expires. The adopt drain and the invalidated stage-metadata drain assert `scope.endCount == 1` after that wait. `make lint` with SwiftFormat 0.62.1 and SwiftLint exited 0: 0/793 files need formatting, and the lint has no serious violations. Mac `make test` was not run. This run did not observe a live Files provider hang.

### Previous head `142e07d`

Command, from `Packages/WorkspaceKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme WorkspaceKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-06-r3-dd \
  -resultBundlePath /tmp/plainsong-ios-06-r3d-results.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

| Item | Value |
|---|---|
| When | 2026-10-16 00:18:53 +0800 through 00:19:08 +0800 |
| Destination | iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0 (`24A5355p`), arm64 simulator |
| Xcode | 27.0 build `27A5194q` at `/Applications/Xcode-beta.app` |
| Compile SDK | iPhoneSimulator 27.0, target `arm64-apple-ios26.0-simulator` |
| Result | `TEST SUCCEEDED`. `totalTestCount` 104, `passedTests` 104, `failedTests` 0, `skippedTests` 0 |
| Log | `/tmp/plainsong-ios-06-r3d-test.log` SHA-256 `452cf2726bbcbf2f5a225c80ec7ed2b2f9078a10ebf889b36deb5c8277820de9` |
| Summary | `/tmp/plainsong-ios-06-r3d-summary.json` SHA-256 `a7f5e3f6eab55f9ab288677f998501e5ed84aed2d72d70474e392acdf910dbc9` |
| XCResult content hash | `/tmp/plainsong-ios-06-r3d-results.xcresult` SHA-256 of sorted relative path, a NUL byte, then file bytes `5bca3e2ffe743f1b464faa6ab7dc8c2d45d1d058677d2ca4795c5155ff11bdc9` (248 files) |

The 104 cases are the previous 84 plus these 20:

- `IOSWorkspaceWriteDeadlineTests/testDeadlineNilIdentityLateSuccessRetainsTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testDeadlineNilIdentityLateUnreadableRetainsTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testDeadlineProvedIdentityLateSuccessRemovesTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testDeadlineProvedIdentityLateUnreadableRemovesTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testCancelNilIdentityLateSuccessRetainsTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testCancelNilIdentityLateUnreadableRetainsTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testCancelProvedIdentityLateSuccessRemovesTheLeaf`
- `IOSWorkspaceWriteDeadlineTests/testCancelProvedIdentityLateUnreadableRemovesTheLeaf`
- `IOSWorkspaceEffectDeadlineTests/testValidateDeadlineReturnsWhileMetadataStaysParked`
- `IOSWorkspaceEffectDeadlineTests/testValidateCancelReturnsWhileMetadataStaysParked`
- `IOSWorkspaceEffectDeadlineTests/testAdoptDeadlineEndsScopeOnlyAfterMetadataDrains`
- `IOSWorkspaceEffectDeadlineTests/testAdoptCancelEndsScopeOnlyAfterMetadataDrains`
- `IOSWorkspaceEffectDeadlineTests/testStageMetadataDeadlineHoldsTheLeaseUntilDrain`
- `IOSWorkspaceEffectDeadlineTests/testStageMetadataDeadlineRemovesAProvedLeafOnDrain`
- `IOSWorkspaceEffectDeadlineTests/testStageMetadataCancelHoldsTheLeaseUntilDrain`
- `IOSWorkspaceEffectDeadlineTests/testStageMetadataDeadlineKeepsScopeUntilDrainAfterInvalidate`
- `IOSWorkspaceEffectDeadlineTests/testRollbackDeadlineRetainsUntilTheRemoveDrains`
- `IOSWorkspaceEffectDeadlineTests/testRollbackCancelRetainsUntilTheRemoveDrains`
- `IOSWorkspaceEffectDeadlineTests/testReclaimDeadlineHoldsTheOperationUntilTheRemoveDrains`
- `IOSWorkspaceAliasRootTests/testAliasRootListReadAndRepeatReadUseTheLogicalGrantLocation`

SwiftFormat 0.62.1 (`/private/tmp/plainsong-swiftformat-0.62.1/swiftformat`, with `--disable wrapIfStatementBodies,wrapIfExpressionBodies`) reports 0/13 touched files require formatting. Mac `make test` was not run. Swift 6 would reject `NSLock` inside the scripted port's async methods; this package is not in Swift 6 language mode, and those warnings did not fail the run.

### Previous head `fe6b7f0`

Command, from `Packages/WorkspaceKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme WorkspaceKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-06-fix-dd \
  -resultBundlePath /tmp/plainsong-ios-06-fix2-results.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

| Item | Value |
|---|---|
| When | 2026-10-15 23:09:05 +0800 through 23:09:16 +0800 |
| Destination | iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0 (`24A5355p`), arm64 simulator |
| Xcode | 27.0 build `27A5194q` at `/Applications/Xcode-beta.app` |
| Compile SDK | iPhoneSimulator 27.0, target `arm64-apple-ios26.0-simulator` |
| Result | `TEST SUCCEEDED`. `totalTestCount` 84, `passedTests` 84, `failedTests` 0, `skippedTests` 0 |
| Log | `/tmp/plainsong-ios-06-fix2-test.log` SHA-256 `10b187959dee0928f786d5938ad2e90e13c6fa3557c1cad99d248d0539928b4a` |
| Summary | `/tmp/plainsong-ios-06-fix2-summary.json` SHA-256 `3665c6bcff8cd7d9fdd13b3c25851c6efe79217c6258b542d5a91bce0041dec4` |
| XCResult content hash | `/tmp/plainsong-ios-06-fix2-results.xcresult` SHA-256 of sorted relative path, a NUL byte, then file bytes `1bff6463a4912334ab251b81aa8eb22dc572d0fda609232bb48faba3d8a63ac9` (208 files) |

The 84 cases are the previous 65 plus these 19:

- `IOSWorkspaceNestedListingTests/testNestedListingUsesEachDirectoryURL`
- `IOSWorkspaceNestedListingTests/testCancelledNestedListingDrainsAfterThePortReturns`
- `IOSWorkspaceNestedListingTests/testProductionTwoLevelFolderListsFiniteChildURLs`
- `IOSWorkspaceAssetRecoveryTests/testSameSizeReplacementWithANewIdentityIsRetained`
- `IOSWorkspaceAssetRecoveryTests/testMetadataSnapshotDoesNotAuthorizeDeletingAReplacement`
- `IOSWorkspaceAssetRecoveryTests/testNilIdentityRollbackRetainsTheLeaf`
- `IOSWorkspaceAssetRecoveryTests/testRollbackLeavesAnotherOperationsLeaf`
- `IOSWorkspaceAssetRecoveryTests/testInvalidateBetweenPersistAndAcceptKeepsAReceipt`
- `IOSWorkspaceAssetRecoveryTests/testMetadataFailureAfterPersistDoesNotLeaveAnUnreceiptedLeaf`
- `IOSWorkspaceAssetRecoveryTests/testProvedIdentityIsRemovedWhenPublishFails`
- `IOSWorkspaceNoticeRoutingTests/testTwoRootsDoNotShareARelativePathNotice`
- `IOSWorkspaceNoticeRoutingTests/testOfflineNoticeStaysOnTheOriginatingRoot`
- `IOSWorkspaceNoticeRoutingTests/testLateNoticeAfterInvalidateDoesNotReachANewRoot`
- `IOSWorkspaceGrantBoundaryTests/testAncestorSymlinkCannotReadOrWriteASiblingRoot`
- `IOSWorkspaceGrantBoundaryTests/testProductionRemoveWithoutProviderIdentityKeepsTheLeaf`
- `IOSWorkspaceCoordinationDeadlineTests/testBlockingPresenterHitsThePortDeadlineWithoutRunningTheReader`
- `IOSWorkspaceCoordinationDeadlineTests/testCancellingABlockedCoordinateReturnsBeforeThePresenter`
- `IOSWorkspaceCoordinationDeadlineTests/testCallerDeadlineFencesLateBytesUntilTheReadDrains`
- `IOSWorkspaceCoordinationDeadlineTests/testTaskCancelDrainsOnlyAfterThePortReturns`

SwiftFormat 0.62.1 left the split test-support files unchanged. Mac `make test` was not run. Swift 6 would reject `NSLock` inside the scripted port's async methods; this package is not in Swift 6 language mode, and those warnings did not fail the run.

### Previous head `576c206`

Command, from `Packages/WorkspaceKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme WorkspaceKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-06-dd \
  -resultBundlePath /tmp/plainsong-ios-06-results.xcresult \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

| Item | Value |
|---|---|
| When | 2026-10-15 17:55:09 +0800 through 17:55:44 +0800 |
| Destination | iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0 (`24A5355p`), arm64 simulator |
| Xcode | 27.0 build `27A5194q` at `/Applications/Xcode-beta.app` |
| Compile SDK | iPhoneSimulator 27.0, target `arm64-apple-ios26.0-simulator` |
| Result | `TEST SUCCEEDED`. `totalTestCount` 65, `passedTests` 65, `failedTests` 0, `skippedTests` 0 |
| Log | `/tmp/plainsong-ios-06-test.log` SHA-256 `38e2c0b4f68c5e0b54bba77512c5417ae9a88ea590ecbfa91b67a948026507fc` |
| Summary | `/tmp/plainsong-ios-06-summary.json` SHA-256 `44d8ef463145f504021c3163a5f4a50f54dd16d46343b92ea4393763c90ede30` |
| XCResult content hash | `/tmp/plainsong-ios-06-results.xcresult` SHA-256 of sorted relative path plus bytes `5fa01b120c61ecb9a31f1ddeae0e4178910d67833f108689b6e05759620b8e34` (170 files) |

The 65 cases are the existing lane 05 document suite plus these 19:

- `IOSWorkspaceLeaseRaceTests/testTwoConsumersEarlyReleaseDoesNotStopScope`
- `IOSWorkspaceLeaseRaceTests/testCancelledReadHoldsScopeUntilTheOperationDrains`
- `IOSWorkspaceLeaseRaceTests/testLateReadAfterInvalidationDoesNotReturnBytes`
- `IOSWorkspaceLeaseRaceTests/testRevokedGrantRejectsANewLeaseWhileDraining`
- `IOSWorkspaceBookmarkTests/testFreshStaleDeniedAndOfflineBookmarks`
- `IOSWorkspaceBookmarkTests/testRecentsKeepTenSuccessesAndDoNotDeleteFiles`
- `IOSWorkspaceBookmarkTests/testSingleFileGrantDoesNotReadASibling`
- `IOSWorkspaceProductionBookmarkTests/testLocalBookmarkRoundTripLeavesProviderIdentityUnknown` (0.607 s, not skipped)
- `IOSWorkspaceSnapshotRaceTests/testLateRefreshAfterANewGrantDoesNotPublishIntoTheNewRoot`
- `IOSWorkspaceSnapshotRaceTests/testSupersededRefreshDoesNotReplaceTheCurrentTree`
- `IOSWorkspaceSnapshotRaceTests/testOfflineRefreshKeepsThePreviousTree`
- `IOSWorkspaceSnapshotRaceTests/testUnicodeSpellingsStayDistinctWhenProviderIdentityCollides`
- `IOSWorkspaceSnapshotRaceTests/testExternalReportDoesNotCoordinate`
- `IOSWorkspaceSnapshotRaceTests/testEmptyFileReadIsSuccess`
- `IOSWorkspaceSnapshotRaceTests/testReadFailureDoesNotReturnEmptyBytes`
- `IOSWorkspaceAssetAndPreviewTests/testSingleFileGrantDoesNotStageIntoParent`
- `IOSWorkspaceAssetAndPreviewTests/testRollbackRemovesOnlyTheFailedOperation`
- `IOSWorkspaceAssetAndPreviewTests/testPreviewReaderHoldsTheLeaseUntilTheReadFinishes`
- `IOSWorkspaceAssetAndPreviewTests/testSingleFilePreviewDoesNotReadASibling`

SwiftFormat 0.62.1 (`/private/tmp/plainsong-swiftformat-0.62.1/swiftformat`, with `--disable wrapIfStatementBodies,wrapIfExpressionBodies`) reports 0/20 lane files need formatting. After the simulator run it reordered one modifier in `IOSWorkspaceAccessService+Preview.swift`: `nonisolated fileprivate static func previewFailure` became `fileprivate nonisolated static func previewFailure`. Probed file SHA-256 `32159d3390f082b3cfae77e7ba1d7bda8084de48230a5de72a43e4d303494197`. Committed file SHA-256 `394d3ae37ab8bd46a225590afa2fb01a0dd9a5eb8d0aa2fbb98aecd29af40cac`. No other probed Swift input differs. SwiftLint 0.65.0 reports warnings only on the new files (`type_body_length`, `function_body_length`, `optional_data_string_conversion`) and exits 0. Mac `make test` was not run.

The 104-test run at `142e07d`, the 84-test run at `fe6b7f0`, and the 65-test run at `576c206` are previous heads. They are not this head. Other historical results that are not this head: public simulator c1 294/294, storage 46/46, Mac CI run `38372199432`, and lint failure `38769236135` on `142e07d`. Partial bundles from the previous fix (`/tmp/plainsong-ios-06-r3-results.xcresult`, `r3b`, and `r3c`) are not this head.

## Guard-removal probes

`docs/ios/evidence/lane-06/run-negative-probes.py` copies MarkdownCore, WorkspaceCore, PreviewKit, and WorkspaceKitIOS into a disposable snapshot, mutates only that snapshot, and restores the fingerprint. The worktree was not mutated. Each accepted probe is exit 65, `totalTestCount` 1, `failedTests` 1, `skippedTests` 0, and the named selector in `testFailures`.

### This head

```sh
python3 docs/ios/evidence/lane-06/run-negative-probes.py \
  --source /private/tmp/plainsong-ios-06-workspace-access \
  --output /tmp/plainsong-ios-06-r4-probes \
  --device 59CB04BD-26CC-4841-8D06-E75A2EDEBC66 \
  --expected-count 107
```

Recorded `runs.json` SHA-256 `4c5a63738c12ea61bf04b5f1aef3f3af058c24c6c8869c96a271d05781b5faef`. Input fingerprint file SHA-256 `d09847a935da8117cacc56a9be01febbc8a64e2a77a6572c114944653cfa8683`. Raw logs, xcresults, and DerivedData stay under `/tmp/plainsong-ios-06-r4-probes` and are not committed. The restored module passed 107, failed 0, skipped 0.

| Label | Guard removed | Named failure | Exit | Accepted |
|---|---|---|---|---|
| `empty-failure` | `LANE06_GUARD_EMPTY_FAILURE` swallows the read error into empty `Data` | `IOSWorkspaceSnapshotRaceTests/testReadFailureDoesNotReturnEmptyBytes` — `failed read returned 0 bytes` | 65 | yes |
| `directory-grant` | `LANE06_GUARD_DIRECTORY_GRANT` skips `requiresDirectoryGrant` | `IOSWorkspaceAssetAndPreviewTests/testSingleFileGrantDoesNotStageIntoParent` — `single-file grant staged an image` | 65 | yes |
| `single-file-scope` | `LANE06_GUARD_SINGLE_FILE_SCOPE` authorizes the parent directory | `IOSWorkspaceBookmarkTests/testSingleFileGrantDoesNotReadASibling` — `sibling read succeeded` | 65 | yes |
| `denied-bookmark` | `LANE06_GUARD_DENIED_BOOKMARK` ignores bookmark resolution failure | `IOSWorkspaceBookmarkTests/testFreshStaleDeniedAndOfflineBookmarks` — `denied bookmark issued a grant` | 65 | yes |
| `consumer-count` | `LANE06_GUARD_CONSUMER_COUNT` skips the decrement | `IOSWorkspaceLeaseRaceTests/testTwoConsumersEarlyReleaseDoesNotStopScope` — `XCTAssertEqual failed: ("Optional(2)") is not equal to ("Optional(1)")` | 65 | yes |
| `generation` | `LANE06_GUARD_GENERATION` accepts a stale generation | `IOSWorkspaceLeaseRaceTests/testLateReadAfterInvalidationDoesNotReturnBytes` — `late read published bytes` | 65 | yes |
| `restored-module` | Sources restored to the probe fingerprint | 107 passed, 0 failed, 0 skipped | 0 | yes |

Every probe row has `restored_all_inputs: true`.

### Previous head `142e07d`

```sh
python3 docs/ios/evidence/lane-06/run-negative-probes.py \
  --source /private/tmp/plainsong-ios-06-workspace-access \
  --output /tmp/plainsong-ios-06-r3-probes \
  --device 59CB04BD-26CC-4841-8D06-E75A2EDEBC66 \
  --expected-count 104
```

Recorded `runs.json` SHA-256 `fee2ad31c4e502be5d5ffc60e6a1e9146faf33d1459d3e525640981250bbb779`. Input fingerprint file SHA-256 `b1ebe0e0ce6375adbbe91b1cec9e6d33a42db2a3e4cae21f8bb370c7cab0d653`. Raw logs, xcresults, and DerivedData stay under `/tmp/plainsong-ios-06-r3-probes` and are not committed. This record is historical. The restored module passed 104, failed 0, skipped 0.

| Label | Guard removed | Named failure | Exit | Accepted |
|---|---|---|---|---|
| `empty-failure` | `LANE06_GUARD_EMPTY_FAILURE` swallows the read error into empty `Data` | `IOSWorkspaceSnapshotRaceTests/testReadFailureDoesNotReturnEmptyBytes` — `failed read returned 0 bytes` | 65 | yes |
| `directory-grant` | `LANE06_GUARD_DIRECTORY_GRANT` skips `requiresDirectoryGrant` | `IOSWorkspaceAssetAndPreviewTests/testSingleFileGrantDoesNotStageIntoParent` — `single-file grant staged an image` | 65 | yes |
| `single-file-scope` | `LANE06_GUARD_SINGLE_FILE_SCOPE` authorizes the parent directory | `IOSWorkspaceBookmarkTests/testSingleFileGrantDoesNotReadASibling` — `sibling read succeeded` | 65 | yes |
| `denied-bookmark` | `LANE06_GUARD_DENIED_BOOKMARK` ignores bookmark resolution failure | `IOSWorkspaceBookmarkTests/testFreshStaleDeniedAndOfflineBookmarks` — `denied bookmark issued a grant` | 65 | yes |
| `consumer-count` | `LANE06_GUARD_CONSUMER_COUNT` skips the decrement | `IOSWorkspaceLeaseRaceTests/testTwoConsumersEarlyReleaseDoesNotStopScope` — `XCTAssertEqual failed: ("Optional(2)") is not equal to ("Optional(1)")` | 65 | yes |
| `generation` | `LANE06_GUARD_GENERATION` accepts a stale generation | `IOSWorkspaceLeaseRaceTests/testLateReadAfterInvalidationDoesNotReturnBytes` — `late read published bytes` | 65 | yes |
| `restored-module` | Sources restored to the probe fingerprint | 104 passed, 0 failed, 0 skipped | 0 | yes |

Every probe row has `restored_all_inputs: true`.

### Previous head `fe6b7f0`

```sh
python3 docs/ios/evidence/lane-06/run-negative-probes.py \
  --source /private/tmp/plainsong-ios-06-workspace-access \
  --output /tmp/plainsong-ios-06-fix-probes \
  --device 59CB04BD-26CC-4841-8D06-E75A2EDEBC66 \
  --expected-count 84
```

Recorded `runs.json` SHA-256 `64ecc112fba256e30383e72461a8f69bb45906c080ce6e880ac98640dda49b63`. Input fingerprint file SHA-256 `6acfa044010075f4550ba97c075ece331032429f391bf1599f68921450ee5b1c`. Raw logs, xcresults, and DerivedData stay under `/tmp/plainsong-ios-06-fix-probes` and are not committed. This record is historical. The restored module passed 84, failed 0, skipped 0.

| Label | Guard removed | Named failure | Exit | Accepted |
|---|---|---|---|---|
| `empty-failure` | `LANE06_GUARD_EMPTY_FAILURE` swallows the read error into empty `Data` | `IOSWorkspaceSnapshotRaceTests/testReadFailureDoesNotReturnEmptyBytes` — `failed read returned 0 bytes` | 65 | yes |
| `directory-grant` | `LANE06_GUARD_DIRECTORY_GRANT` skips `requiresDirectoryGrant` | `IOSWorkspaceAssetAndPreviewTests/testSingleFileGrantDoesNotStageIntoParent` — `single-file grant staged an image` | 65 | yes |
| `single-file-scope` | `LANE06_GUARD_SINGLE_FILE_SCOPE` authorizes the parent directory | `IOSWorkspaceBookmarkTests/testSingleFileGrantDoesNotReadASibling` — `sibling read succeeded` | 65 | yes |
| `denied-bookmark` | `LANE06_GUARD_DENIED_BOOKMARK` ignores bookmark resolution failure | `IOSWorkspaceBookmarkTests/testFreshStaleDeniedAndOfflineBookmarks` — `denied bookmark issued a grant` | 65 | yes |
| `consumer-count` | `LANE06_GUARD_CONSUMER_COUNT` skips the decrement | `IOSWorkspaceLeaseRaceTests/testTwoConsumersEarlyReleaseDoesNotStopScope` — `("Optional(2)") is not equal to ("Optional(1)")` | 65 | yes |
| `generation` | `LANE06_GUARD_GENERATION` accepts a stale generation | `IOSWorkspaceLeaseRaceTests/testLateReadAfterInvalidationDoesNotReturnBytes` — `late read published bytes` | 65 | yes |
| `restored-module` | Sources restored to the probe fingerprint | 84 passed, 0 failed, 0 skipped | 0 | yes |

Every probe row has `restored_all_inputs: true`.

### Previous head `576c206`

```sh
python3 docs/ios/evidence/lane-06/run-negative-probes.py \
  --source /private/tmp/plainsong-ios-06-workspace-access \
  --output /tmp/plainsong-ios-06-probes \
  --device 59CB04BD-26CC-4841-8D06-E75A2EDEBC66 \
  --expected-count 65
```

Recorded `runs.json` SHA-256 `684436f7ad7dbf55872d25da53c3c83088e69d5317ec18d483c7cd0278014dae`. Input fingerprint SHA-256 `241cff18a82827a792a906b1a4adebd7d756662adee703df75145f9f7096fa36`. Raw logs, xcresults, and DerivedData stay under `/tmp/plainsong-ios-06-probes` and are not committed. This record is historical. The same six selectors failed, and the restored module was 65/65/0 skipped.

## Still open

- Owner device steps in [device-acceptance.md](device-acceptance.md).
- Real Files and iCloud in-place grants, offline placeholders, and provider identity.
- Exact-head CI for this branch.
- Performance budgets. This run is a functional simulator module run.
- Lane 13 production composition and the Decision Log row below. No frozen-contract change is requested.
- Lane 12 still owns `project.yml`, the Makefile, `Scripts/ios/**`, and the iOS workflow.

## Suggested Decision Log row for lane 13

Date 2026-10-16. Decision: iOS workspace access is one `IOSWorkspaceAccessService` from `IOSWorkspaceAccessFactory.makeProduction()`, with explicit single-file and directory grants, reference-counted leases, and scope release only after revoke and idle drain. Nested listing uses each directory URL. Rollback and unpublished cleanup delete a leaf only when one coordinated remove proves provider identity; otherwise the leaf stays with a receipt. A late create returns a retained receipt at the deadline or cancellation. Its operation ticket stays until the late result is removed or kept. Metadata and remove each hold the scope until their own port returns. Public snapshot and read locations stay on the logical grant URL. The proved path is internal I/O metadata. Stage metadata, validate, rollback, reclaim, and adopt metadata return on a deadline and drain afterward. External notices stay on the originating grant. Realpath ancestry inside the accessor rejects an ancestor symlink. The caller deadline does not wait out a blocked coordinator. Why: a URL or inode is not a File Provider identity, a single-file grant must not authorize its parent, a same-size replacement is not ownership, a canonical listing must still authorize against the original grant, a timed-out write must not leave an unreceipted file, and a late read after invalidation must not publish bytes. Alternatives: security-scoped bookmark options (unavailable on iOS), treating empty `Data` as a failed read, treating byte count as ownership, relaxing literal containment for canonical paths, discarding a late write the way a late read is discarded, and downloading every ubiquitous item to draw the tree. Those were rejected.
