# Relaunch recovery UI candidate — 2026-10-23

Feature branch: `codex/ios-recovery-ui-20261023`.
Expected PR base: `codex/ios-main-production-20261023` at
`1c1685adb7a594f3ecaf81a16d61f5d41e032363`, pending maintainer integration to main.
This is a separate feature candidate after the formal-App integration. It does not
reuse the parent IPA/native receipts as execution evidence for these new sources.

Implemented: Files-visible Recovered Drafts; reloaded disk list and corrupt-record
notice; fresh selected-record readback; read-only Unicode source; explicit folder
picker; guarded Restore as New File through the existing UIDocument store. Empty,
read-failure, stale-context, collision, retained-close and access-error outcomes are
presented. Records are retained, including after success. Save a Copy, recents and
Try Again repairs are outside this PR. No frozen declaration, global manifest,
preview source or generated preview resource changed.

The implementation author performed static review, scoped formatting and diff
checks only. **Native tests/build/UI were not run by this author** because one root
executor owns the canonical Xcode lock. The following new cases are ready for that
executor; source commit and its actual execution receipts must be bound separately.

Static checks: repository-pinned SwiftFormat 0.62.1 reports 0/12 touched Swift
files requiring formatting; scoped SwiftLint (`--no-cache`) exits 0 with zero
serious violations and nine warnings in inherited composition/store files, with
no warnings in the new recovery implementation files; `git diff --check` passes.

## New named cases (17, not yet execution claims)

App-hosted `PlainsongIOSTests`:

- `IOSRecoveryRestoreTests/testNewerLiveRevisionRefusesRestoreBeforeAnyGrantOrClose`
- `IOSRecoveryRestoreTests/testRecordReadSuspendsWithEditorDisabledAndRejectsNewerSource`
- `IOSRecoveryRestoreTests/testRetainedClosePreservesOriginalConflictBindingAndAdmission`
- `IOSRecoveryRestoreTests/testDestinationCollisionRefusesBeforeClosingOriginal`
- `IOSRecoveryRestoreTests/testSourceChangeDuringSafeCloseCannotInstallOlderRecovery`
- `IOSRecoveryRestoreTests/testDestinationRevokedDuringCloseCannotCreateAFile`
- `IOSRecoveryRestoreTests/testDocumentRoundTripInvalidatesTheOldRestoreCapture`
- `IOSRecoveryRestoreTests/testReplacingTheNativeBindingRejectsTheOldRestoreCapture`
- `IOSRecoveryRestoreTests/testCancelledIssuanceAfterRecordReadCannotCloseOrCreate`
- `IOSRecoveryRestoreTests/testCanonicallyEqualChangedRecoveryBytesCannotBeRestored`
- `IOSRecoveryControllerTests/testLateSelectionReadCannotReplaceTheNewerDetail`
- `IOSRecoveryControllerTests/testCancelledAndLateFolderCompletionsCannotRestoreANewIssuance`
- `IOSRecoveryControllerTests/testCorruptReadShowsAnErrorWithoutLosingReadableSiblings`
- `IOSRecoveryProductionWorkflowTests/testRelaunchReadbackRestoresANewUIDocumentAndPreservesOriginalAndRecovery`
- `IOSRecoveryProductionWorkflowTests/testReadOnlyRecoveryPresentationRetiresPendingCommandFocusAndAuthoringCapture`

WorkspaceKitIOS native module:

- `IOSDocumentRecoveryTests/testDocumentStoreRecreationReadsRecoveryAndPreservesCorruptSibling`
- `IOSDocumentRecoveryTests/testDocumentStoreRecoveryReadRejectsMismatchedRecordIdentity`

Use the existing serialized native runner and retain enabled scheme/test-host,
executed named counts and full xcresult; package build-only or zero execution is
not acceptance. The real workflow uses a temporary recovery directory in the actual
production factory. It persists a previous-run record, re-creates the store, reads
the draft, safely closes a real original document, creates a separate MDX through
UIDocument, and checks unchanged original bytes plus retained record readback.

## 中文手動驗收（新 source/artifact，待 owner）

1. 在正式 App 編輯測試 Markdown，藉背景儲存或外部衝突產生復原稿；記錄
   app/source、裝置與 OS。重新啟動後，在 Files 底部選 Recovered Drafts。
2. 核對清單與唯讀內容：繁中、emoji、換行與完整 source 可讀；選不同稿不被
   延遲讀取跳回舊稿。沒有稿時顯示空狀態；損壞一份稿不隱藏其他可讀稿。
3. 選 Restore as New File，先取消一次，確認原文件及復原稿不變。再次選擇明確
   的本機或 iCloud 資料夾，核對新 `Recovered-<record UUID>.md/.mdx` 內容、
   原檔未變、復原稿仍存在；新檔可繼續原生編輯、儲存及重開。
4. 重複還原到相同資料夾應拒絕同名覆寫；改選另一資料夾才建立另一副本。
   有未解決 conflict 或 retained close 時應拒絕替換，保留當前原稿。
5. 驗證 iPhone、小/寬 iPad、旋轉、最低 OS26、VoiceOver 閱讀與按鈕、外接鍵盤
   焦點/取消；記錄大稿開清單/讀回/還原耗時。沒有設備證據的項目維持待補。

These owner checks are separate from parent M0 reports, simulator provider
workflows, the prior composition IPA and exact-head Mac/JS CI.
