# 05 — iOS 文件 I/O、自動儲存、衝突與復原

## 任務與智力需求

- **建議：L4 最高階推理，需獨立 review。** 必須處理 UIDocument／File Provider、序列化 writer、舊 save completion、外部更新、背景中斷與 durable recovery；錯誤會造成真實內容遺失，單一 happy-path test 無法驗收。
- Branch：`phase3-ios-document-io`。依 [總表](../README.md) 在自己的 isolated worktree 開發。
- 目標：實作 C0 的 `@MainActor IOSDocumentStore`，用 UIDocument adapter 管理 in-place 文件開啟、新建、儲存、外部變更及 recovery。Canonical source 永遠是同一個 `DocumentSession`；不能另建立編輯文字鏡像作權威。
- 不做 file picker／bookmark store／directory scan／workspace UI；不做 rename、move、delete、跨檔 Replace All 或 sync engine。

## 起跑條件與並行關係

1. 13 integrator 完成 C0：凍結 WorkspaceKitIOS manifest、`Contracts.swift`、test doubles 和 save acknowledgement 契約後才起跑。
2. 依賴 C0 MarkdownCore 的 iOS support／document identity／revision、03 WorkspaceCore 型別。以既有 `rebaseSavedText(to:)` 做 guarded baseline acknowledgement；06 access lane 提供 leases 與協調操作服務。01 專責 M0 真機驗證。
3. 和 06 同時用 C0 mocks 開發文件 lifecycle／race tests。只在真實 access provider 到位且 M0 owner 真機 Files／iCloud／IME／簽名啟動關卡通過後做產品接線。
4. 若 M0 尚未通過，可交付 provider prototypes 與 recovery tests，狀態必須保留「M0 blocked／manual open」，不能繼續當作完整 M3 完成。

## Exclusive write paths

- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/**`
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Recovery/**`
- `Packages/WorkspaceKitIOS/Tests/WorkspaceKitIOSTests/Documents/**`
- `Packages/WorkspaceKitIOS/Tests/WorkspaceKitIOSTests/Recovery/**`
- 本 handoff 的 evidence section。

禁止修改 WorkspaceKitIOS `Package.swift`／`Contracts.swift`、Access／Workspace directories、MarkdownCore、AppIOS／UI、PreviewKit、所有 global manifests／build／CI／架構文件。需要新 core method 或 global wiring 時交給 13 integrator；不要兩條 lane 同時寫 shared package files。

## 固定契約與狀態轉移

- Public facade 為 `IOSDocumentStore`，狀態／事件／save receipt 為 `IOSDocumentState`、`IOSDocumentEvent`、`IOSSaveAcknowledgement`。Document identity／revision 使用 MarkdownCore 的 `IOSDocumentIdentity`／`IOSDocumentRevision`。開啟輸入為具 root identity／generation 的 location＋retained access lease，輸出為 session handle 與 C0 狀態；方法及 event payload 嚴格依 contracts.md。
- 每個 provider resource identity 僅有一個 store entry 與 serialized writer；同 root 的 aliases 必須共用 writer。Provider 無穩定 ID 時，不做不可靠的跨 path 合併；root revoke／replace 後，舊 lease completion 不得更新新 entry。
- UIDocument 保留 provider lifecycle／file presentation／版本通知。以明確 immutable snapshot 供 `contents(forType:)`，不能在 callback 偷取會變動的 live text。
- UIDocument 已負責文件協調；不能在其 read／write callbacks 再包一層相同 NSFileCoordinator 操作造成重入／deadlock。外部獨立檢查／save-copy／asset 等輔助操作，使用 06 提供的 coordination facility。
- Save receipt 必須包含 session identity、document identity、revision、真正落盤的 source／baseline 以及 completion 結果。成功只能承認該 snapshot；若本地已是 v+1，live source／selection／undo 不變，dirty 保持依實際 baseline 判定。
- **既有陷阱：** `DocumentSession.markSaved(text:url:)` 會呼叫 applyState、重寫 live source。非同步 completion 不准直接呼叫它；在 store 完成 identity／generation／save order guards 後，對真正已存的 snapshot 呼叫 `rebaseSavedText(to:)`，保留 live source 與新 revision。
- 失敗或 indeterminate completion 不標 clean。Close／workspace switch／background flush 等待 writer drain，無法安全完成時保留 session／recovery；不能以取消 task 證明已停止 provider write。
- Debounce autosave 為既有 1 s 設定；app resign-active／背景時要求 bounded flush。背景 execution 到期先保住 durable recovery，不能宣稱任意 provider write 一定能在背景完成。

## 外部更新與內容保護

1. 用 coordinated read／UIDocument version notification 取得一致 external source；不以 modification date 單獨證明內容相同，也不把自己寫入的通知當外部 conflict。
2. Clean session：完成 identity／generation／revision 檢查後載入，維持 canonical session；editor reconciliation 由 04 contract 處理，不在此 lane 直接改 text view。
3. Dirty session：偵測到外部衝突時先 fence writer／暫停自動覆寫，再將完整 local source、document/root identity、baseline、revision 持久保存到 app-owned recovery store，成功後發布可解決的 conflict。若 recovery 失敗，保留 live session、維持寫入封鎖並回報 error。C0 events 提供「載入外部版本／另存副本」給 App lane。
4. 選載入外部版本前重新讀取最新版，保留 local recovery；另存副本只在新 user-selected destination，以 create-not-overwrite 語義落盤，成功後按 C0 行為處理新 handle，不能暗自 overwrite original。
5. Provider offline、download pending、read-only、搬移／刪除／scope revoke：狀態可重試，內容及 recovery 可讀。新 root／同 path replacement 不接續舊寫入授權。
6. Recovery 原子寫入 app container，重啟可列出與還原；失敗要進入明確 error，仍保留 live session。Recovery 清除須已確認匹配內容存妥且無較新 local revision，不能憑 UI「已存」字樣清除。

## 測試與驗收

- Controlled provider：阻住 save(v1) → edit(v2) → release v1，驗證 v2 source／version 不變、仍 dirty、baseline=v1；再存 v2 才 clean。倒置 callbacks、同時兩次 open alias、writer close／cancel／retry 也要測。
- External clean reload 與 dirty conflict：阻住 external read → 改 root／改 session／edit → release，舊結果不得發布；conflict 後 autosave 沒有任何 original-file write。
- Durable recovery：kill／recreate store 後恢復相同 source／baseline／identity；模擬 disk-full／corrupt record／write failure，不得消失內容或假稱 recovery 已存。
- File failures：離線／下載中、唯讀、已移除、搬移通知、scope revoke、close 失敗、背景期限到期。新建／save-copy 遇 existing destination 拒絕覆寫。
- Negative probes：把 acknowledgement 換回 markSaved、拿掉 writer serialization、拿掉 generation fence、未存 recovery 就發布 conflict，相關測試均須可靠失敗。
- 真機 owner 驗證：本機 Files、iCloud 未下載文件、Mac／iOS 同時修改、背景／重啟、繁體中文組字中收到 external update；模擬器與 doubles 無法關閉這些 manual gates。

## Stop gates 與 PR evidence

- 有任何路徑可能丟失 local bytes、silent overwrite、發出未授權 sibling read／write、或無法證明 completion identity：停在可重現測試與設計，不靠延長 timeout 或放寬 conflict policy 隱藏。
- Shared contract 需要變動先交 integrator；同樣 root URL 不代表同樣 provider authority。不要搬 Mac Darwin root authority 來「補證明」。
- PR 列起跑／base／head SHA、contract version、state machine、named races 與 executed counts、negative-probe 結果、recovery artifact proof、Mac regression、manual／M0 open gates，另附全域文件更新的精確建議。
- 不自行 merge／force-push；L4 reviewer 與 Claude 檢查保護契約後才可整合。完整驗收須區分 local package tests、exact-head CI 與 owner real-device tests。

## Evidence（由執行者填寫）

尚未執行；本文件沒有 UIDocument 實作、背景可靠性或真機驗收證據。

## 可直接貼給其他 LLM 的任務

```text
請執行 Plainsong iOS lane 05：Document I/O，建議 L4 最高階推理。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/05-document-io.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-document-io。只修改 Documents/Recovery 與自己的 tests。
以 UIDocument 實作 IOSDocumentStore、序列化 writer、baseline-only acknowledgement、
外部 conflict fence 與 durable recovery；不要寫 shared Package.swift/Contracts.swift。
先用 frozen doubles；06 真實 providers 與 01 M0 owner gates 通過後才產品接線。
不得以 markSaved 重寫晚於 save snapshot 的文字；失敗保留 draft 與 original。
提供可重現 races、negative probes、SHA/測試結果及真機 open gates給 Claude review。
不自行 merge、force-push 或修改 owner checkout；共享需求交 13 integrator。
```
