# Conflict Save a Copy — implementation handoff

Base: `1c1685adb7a594f3ecaf81a16d61f5d41e032363`.
Branch: `codex/ios-conflict-copy-ui-20261023`.
This is an independent feature addition for a later PR stacked on recovery UI.
It does not change shared runtime/root/controller files or enable its own hook.

## Integration API

```swift
let copy = IOSConflictCopyCoordinator(controller: documentSceneController)
// Retain with the runtime. The existing conflict surface calls:
_ = copy.requestSaveCopy()
// Install exactly once on the production root:
.background(IOSConflictCopyPresenter(coordinator: copy))
```

The coordinator receives the same controller and therefore the same document
store, workspace access service and native editor. `completePicker` returns a
task for testing/coordination; its completion occurs after safe-drain cleanup.
`cancelInFlightCopy` only requests cancellation and does not release scopes early.
The integration owner must also put asynchronous `resolveExternal` under the
same controller transition fence so an already-started reload excludes copy
admission. No changes to that shared file are included here.

## Tests and evidence boundary

[Required names](required-named-tests.txt) lists 18 new cases: 17 controlled
coordinator cases and one real-provider save-copy workflow. The cases cover
picker cancellation/duplicate/altered issuance, stale binding/source/generation,
marked text, resolved conflict, destination open/refresh suspension, occupied and
concurrently-created leaves, revoked destination, N to N+1 during parked copy,
cancellation with safe lease drain, navigation/resolve fencing, Unicode names,
and retained original conflict/dirty/source/native Undo/recovery/autosave barrier.
The already-started reload exclusion case deliberately requires the integration
owner's shared `resolveExternal` transition hook; it must pass after integration,
not be skipped or weakened on this independent source branch.

Terminal feedback is queued while the provider drains and is transferred to the
single outer alert only from the name sheet's actual `onDismiss`. Form validation
has a separate notice state. A controlled case checks lease retention before
completion, no terminal notice before dismissal, and one-time handoff.

The real workflow loads the real file with UIDocument, applies a native editor
edit, durably enters conflict through the store's existing testable method, saves
the copy through the real access service/create-new path, and checks disk bytes,
scope cleanup, original Undo/selection, recovery bytes and actual autosave refusal.
Fixture-only teardown safely retires its writer after assertions; production
Save Copy never closes or retires the original.

**Native tests, UI tests, build, exact-head CI, device acceptance and performance
have not been executed by this feature author.** XcodeGen/xcodebuild/simctl and
all native execution belong to the integration owner's canonical-lock run.
Pinned SwiftFormat 0.62.1, targeted SwiftLint without cache and static contract /
dependency / preview / ownership checks are recorded separately. No native PASS
is inferred from static source or lint.

## 真機／UI 待驗收

1. 在整合後的新 App 產生外部衝突；確認本機草稿及復原記錄仍在。
2. 點「Save a Copy」，以預設唯一檔名或繁中 `.md`／`.mdx` 名稱選 Files／iCloud 資料夾。
3. 確認副本內容正確，原始檔未被覆寫；原畫面仍顯示衝突、原稿及 Undo 歷史。
4. 選擇已有同名檔案，確認提示另取名稱，既有檔案不變。
5. 分別取消檔名表單與資料夾選擇器；原稿、衝突和復原記錄均不變。
6. 在 provider 延遲或撤銷權限時測試；錯誤須明示可能已產生較早副本，保留較新原稿。
7. 確認成功存副本後，自動儲存不回寫仍衝突的原始檔。
8. 在實體 iPad、最低 iOS/iPadOS26、VoiceOver、外接鍵盤完成相同流程並記錄裝置／OS／artifact hash。

Simulator tests do not close these owner gates. This feature does not implement
recovery, recents, retry UI or a new access/writer service.
