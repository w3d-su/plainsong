# Lane 05 receipt — Document I/O

Status: **module-ready**. Not product-integration-ready. M0 device gates are open. Lane 06 real access providers are not wired.

| Field | Value |
|---|---|
| Branch | `phase3-ios-document-io` |
| Base | `refs/tags/ios-c0-v1` / `642cb212703220409874a2741c5adbfb8c80fe8a` |
| Contract | IOS-C0-v1. `Contracts.swift`, `DocumentContracts.swift`, and `Package.swift` were not edited |
| Head | The commit that adds this file on `phase3-ios-document-io` |
| PR base | `phase3-ios-integration` |

## Native review acceptance (2026-10-13)

The final reviewed 46-case source now has **six actual named negative failures with full 148-input restoration**, followed by **46 / 0 failed / 0 skipped** in the restored simulator module. Root runtime dependencies are **117/117 byte equal**; full aggregate comparison remains 138/148. See [native-guard-receipt.md](native-guard-receipt.md) and [native-guard-proof.json](native-guard-proof.json). Earlier compile-only/pending and 31/41-case sections below are retained as historical evidence; this native receipt supersedes their final46 runtime-pending status. Production/device/M0 gates remain open.

## Review repairs (2026-10-13)

The additive batch on `codex/ios-storage-review-fixes` addresses the external-observation write race, suspended-close draft loss, and generation retirement. See [review-fixes.md](review-fixes.md) and the structured [review-verification.json](review-verification.json).

Final source declares **43 cases**. The third generic iOS Simulator build-for-testing attempt completed with **exit 0 / TEST BUILD SUCCEEDED**; the generated XCTest binary contains all **43 unique declared test methods**, with **0 executed**. The first two attempts ended at canonical-lock admission (`exit 75`). Five mutation probes and the final restored simulator run remain pending. The earlier 2026-10-09 candidate actually passed **41 / 0 failed / 0 skipped**, with exact retained source inputs, but that result is version-bound and does not close final-source acceptance. All 13 frozen contract hashes match and SwiftFormat 0.62.1 reports 0/25 document files needing formatting.

## Retained-close autosave follow-up (2026-10-13)

Peer review found that a late-edit autosave could finish while `isClosing` fenced writes, leaving a retained, reopened dirty document without another autosave. Close now rechecks current authority, open/unfenced/writable status, and dirtiness after clearing that transient barrier; eligible drafts schedule a fresh autosave. Read-only, conflicted, retired, or closed entries cannot regain write admission from this follow-up.

The controlled regression waits for the exact old autosave task to finish before releasing the provider close. It then expects a new task to save N+1 while preserving source/version and recovery. Two additional controls verify read-only and conflicting reopen paths do not write. Latest source passed generic build-for-testing (`exit 0`), and all **46 declared test methods appear in the XCTest binary; 0 executed**. The earlier 43-case compilation above is version-bound. The new single-guard failing probe and native regression are pending. See [autosave-review-receipt.json](autosave-review-receipt.json).

## What landed

`IOSUIDocumentStore` is the UIDocument-backed `IOSDocumentStore`. One open instance owns one `DocumentSession`. Save completions call `rebaseSavedText(to:)` after identity, generation, and operation-order checks. They do not call `markSaved(text:url:)`.

Each provider resource has one serialized writer. A stable `resourceID` shares that writer across aliases. Without a resource id, exact relative-path UTF-8 spellings stay separate. A newer root generation replaces the entry; an older save completion cannot revise the replacement session.

`MarkdownUIDocument.contents(forType:)` returns only the snapshot installed for that save. Presenter callbacks do not nest another `NSFileCoordinator` around UIDocument's own read or write. External reads and save-copy use the frozen `IOSCoordinatedFileAccess` seam. Save-copy is create-not-overwrite and does not mark the original clean.

Dirty external conflict fences the writer, writes an atomic recovery record in the app-private directory, and only then publishes `.conflict`. A failed recovery write keeps the live draft, stays fenced, and does not emit `recoveryPersisted`. Background flush writes recovery first and returns `.recovered` or `.retained` when the provider save does not finish inside the budget. Cancelling the caller does not cancel the provider write.

## Doubles

| Seam | This delivery |
|---|---|
| 06 `IOSCoordinatedFileAccess` | Injected. Tests use a continuation gate. Production init requires the caller to pass the real provider |
| UIDocument | Production port is `UIDocumentFileAdapter`. Race tests inject a scripted port |
| 04 external reload | The store emits `externalReloadRequested` and applies `acknowledgeExternalReload` only when the live text already matches the proposal |
| App composition | Not done. 13 wires this after 06 and the M0 Files / iCloud / background gates |

## Simulator verification

Command, from `Packages/WorkspaceKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme WorkspaceKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-document-io-dd2 \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Destination: iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, iOS 27.0 simulator, Xcode 27A5194q. Result on 2026-10-09 02:22:06 +0800: **TEST SUCCEEDED**, 31 tests, 0 failures. That count includes the existing C0 `DocumentStateContractTests` case. Log: `/tmp/plainsong-doc-io-test3.log`.

SwiftFormat 0.62.1 was run on the lane 05 sources and tests. SwiftLint reports no error in `Packages/WorkspaceKitIOS`; four warnings remain (`type_body_length`, `function_body_length`, `function_parameter_count`). Mac `make test` was not run. This lane does not change Mac targets.

## Still open

- Owner device gates in [device-acceptance.md](device-acceptance.md).
- Lane 06 real Files / iCloud leases and coordinated access.
- Lane 13 production composition, after those gates. No frozen-contract change is requested.
- Exact-head CI for this branch. The simulator package run above is the module evidence.

## Suggested Decision Log row for lane 13

Date 2026-10-09. Decision: iOS document persistence is one `IOSUIDocumentStore` per scene, with UIDocument as the only in-place document writer and `rebaseSavedText(to:)` as the only successful baseline update. Why: `markSaved(text:url:)` rewrites live source, and a second coordinator inside UIDocument callbacks can deadlock. Alternatives: a second `FileDocument` store, acknowledging whichever completion arrives last, or treating modification dates as content equality. Those were rejected.
