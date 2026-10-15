# Lane 06 receipt — Workspace access

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

Inside each coordinated accessor, read, list, create, and delete resolve the real path and require it to stay inside the grant root. An ancestor symlink that reaches another root is `.outsideGrant` for read, write, and delete. The accessor returns that proved URL. Literal path comparison remains the single-file scope check. It is not the ancestry proof.

The caller deadline is separate from coordinator drain. When the deadline fires, the caller receives `.coordinationFailed`, the coordinator is cancelled, and a later port result cannot replace that failure. The scope stays up until the port returns and `finish` runs. `NSUserCancelledError` from a coordinator cancel still maps to `.unavailable`. The deadline failure itself is `.coordinationFailed`.

Production bookmarks use `options: []` on create. Resolve uses `.withoutUI`, `.withoutMounting`, and `.withoutImplicitStartAccessing`, then an explicit `startAccessingSecurityScopedResource`. `NSURLBookmarkCreationWithSecurityScope` and `NSURLBookmarkResolutionWithSecurityScope` are unavailable on iOS. The production identity port returns nil until a File Provider port supplies opaque bytes. URL, inode, and `NSURLDocumentIdentifierKey` are not provider identity. Recents keep the last 10 successful opens, dedupe only when a real provider identity exists, and store bookmark bytes off `IOSRecentWorkspaceItem`. `removeRecent` does not delete the file.

External presenter callbacks enqueue `resourceChanged` or `unavailable` and return. They do not implement `savePresentedItemChanges` and do not coordinate. The callback keeps the workspace identity, generation, and root token from the registration that started it. Pending notices coalesce on that tuple plus the relative path. `report` delivers only to the grant that still has the same identity, generation, and root token. An offline notice does not mark any other root offline. A callback that arrives after `invalidate` keeps the old generation and is dropped.

The preview reader holds its lease until the coordinated read finishes, checks the access context again, then releases the lease on the main actor. It returns the original `PreviewAssetAccessContext`. Root, type, size, symlink, and token policy stay with lane 07. `isCurrent` checks root URL, root token, grant identity, generation, and that the grant is still running. It does not grant access.

The image writer requires `grant.scope == .directory` before it creates anything. It returns `IOSStagedImageAsset` only after the leaf exists. Commit and rollback touch that operation's leaf. Rollback deletes the leaf only inside one `removeIfOwned` coordination, and only when that coordination proves the provider identity still matches. A nil identity, a same-size replacement, or a file owned by another operation stays on disk with a receipt. The byte count is not ownership. If `createFile` has stored bytes and the grant cannot be published, the service keeps that leaf on the operation from that moment. It deletes the leaf only when the same protected remove proves ownership. Otherwise `stage` throws `.retained` and the file stays with a receipt. `CancellationError` is used only when no operation-owned leaf remains. Markdown extensions are refused. A missing folder grant surfaces `requiresDirectoryGrant`.

## Typed failures

Callers rethrow `CancellationError` before `IOSWorkspaceFailureMapping`. Cocoa not-found, permission, and already-exists codes map to `.notFound`, `.permissionDenied`, and `.alreadyExists`. `NSUserCancelledError` maps to `.unavailable`. Ubiquitous codes `NSUbiquitousFileUnavailableError` (4353), `NSUbiquitousFileNotUploadedDueToQuotaError` (4354), `NSUbiquitousFileUbiquityServerNotAvailable` (4355), and the range 4352...4607 map to `.offline`. Other errors map to `.coordinationFailed`.

`stage` throws `IOSAssetStageFailure` or `CancellationError`. `validate` throws `IOSWorkspaceFailure` or `CancellationError`. `commit` and `rollback` return `.committed` / `.removed` or `.retained`. Preview failures map `grantChanged` to `accessChanged`, `outsideGrant` and `invalidPath` to `outsideRoot`, and `tooLarge` / `unsupportedType` to the matching preview cases. Remaining workspace failures become `providerFailed`.

A thrown coordinated read stays a failure. An empty file that the provider successfully returns is a successful empty `Data`.

## Provider matrix

| Provider | Exercised by | Result on this head |
|---|---|---|
| Scripted scope, bookmark, identity, and file ports | Lease, bookmark, snapshot, asset, and preview tests below | Simulator pass |
| Local temp-file bookmark (`IOSSystemAccessPorts`, no security-scope bookmark option) | `testLocalBookmarkRoundTripLeavesProviderIdentityUnknown` | Simulator pass. Provider identity is nil. This is a local bookmark round trip |
| `NSFileCoordinator` production file port | Two-level temp-directory listing, ancestor-symlink refusal, nil-identity remove, and a blocking-presenter deadline. Race tests still use the scripted port | Files and iCloud in-place use is open |
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

The 65-test run above is the previous head. It is not this head. Other historical results that are not this head: public simulator c1 294/294, storage 46/46, Mac CI run `38372199432`.

## Guard-removal probes

`docs/ios/evidence/lane-06/run-negative-probes.py` copies MarkdownCore, WorkspaceCore, PreviewKit, and WorkspaceKitIOS into a disposable snapshot, mutates only that snapshot, and restores the fingerprint. The worktree was not mutated. Each accepted probe is exit 65, `totalTestCount` 1, `failedTests` 1, `skippedTests` 0, and the named selector in `testFailures`.

### This head

```sh
python3 docs/ios/evidence/lane-06/run-negative-probes.py \
  --source /private/tmp/plainsong-ios-06-workspace-access \
  --output /tmp/plainsong-ios-06-fix-probes \
  --device 59CB04BD-26CC-4841-8D06-E75A2EDEBC66 \
  --expected-count 84
```

Recorded `runs.json` SHA-256 `64ecc112fba256e30383e72461a8f69bb45906c080ce6e880ac98640dda49b63`. Input fingerprint file SHA-256 `6acfa044010075f4550ba97c075ece331032429f391bf1599f68921450ee5b1c`. Raw logs, xcresults, and DerivedData stay under `/tmp/plainsong-ios-06-fix-probes` and are not committed. The restored module passed 84, failed 0, skipped 0.

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

Date 2026-10-15. Decision: iOS workspace access is one `IOSWorkspaceAccessService` from `IOSWorkspaceAccessFactory.makeProduction()`, with explicit single-file and directory grants, reference-counted leases, and scope release only after revoke and idle drain. Nested listing uses each directory URL. Rollback and unpublished cleanup delete a leaf only when one coordinated remove proves provider identity; otherwise the leaf stays with a receipt. External notices stay on the originating grant. Realpath ancestry inside the accessor rejects an ancestor symlink. The caller deadline does not wait out a blocked coordinator. Why: a URL or inode is not a File Provider identity, a single-file grant must not authorize its parent, a same-size replacement is not ownership, and a late read after invalidation must not publish bytes. Alternatives: security-scoped bookmark options (unavailable on iOS), treating empty `Data` as a failed read, treating byte count as ownership, and downloading every ubiquitous item to draw the tree. Those were rejected.
