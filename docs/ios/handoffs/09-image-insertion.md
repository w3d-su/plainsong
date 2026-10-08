# 09 — 圖片插入與協調檔案交易

## 任務與智力需求

提供從 Photos／Files 插入圖片的 iOS 流程：先在授權資料夾協調保存圖片，再以原 native editor guarded route 插入相對 Markdown 路徑。處理保存期間的切檔、編輯、選取與权限變化，避免圖片存到錯目錄或舊命令改到新文件。

| 項目 | 要求 |
|---|---|
| 最低智力 | **L4／最高** |
| 原因 | async import、file provider／security scope、持久化與文字修改是兩個不同 transaction；需處理 stale revision、namespace／authority 變化與 rollback，不能只 await 保存後 append source。 |
| 分支 | `phase3-ios-image-insertion` |
| 一個 PR 的終點 | Image UI／orchestrator、同契約 fake writer／editor tests、可接 06 writer 與 04 editor 的交易流程；不重做 workspace I/O 或 Mac image implementation。 |

先讀 [協作總覽](../README.md)、[共用契約](../contracts.md)、`agent.md`。歷史盤點基準為 `main b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`；實際開工從 C0 契約凍結 commit。

## 依賴與可同步範圍

- C0 凍結 `IOSWorkspaceAssetWriting`、`IOSStagedImageAsset`、`IOSAuthorizedEdit` 與 snapshot；06 實作安全 scope、coordinated asset writer／disposal；04 實作 native guarded mutation。
- 06／04 未完成前使用**private、同 frozen protocol 的 mocks**，可同步實作 orchestration 和故障／race tests。不公開另一套 image store contract，不直接呼叫 FileManager／URL 寫入來做 product fallback。
- 10 shell 組裝 entrypoint 與提示 UI，13 負責 production provider composition；07 preview 消費相同已授權 workspace asset root。本 lane 不改 preview handler 或其安全政策。
- **Module-ready 不代表 Files/iCloud/M0 product integration-ready。** 真機 Files 授權、尚未下載資產、背景 provider 寫入、actual IME 與自行簽名後資源存取須另留驗收證據。

## 檔案所有權

**只准本 lane 寫：** `AppIOS/Features/Images/`、`AppIOSTests/Images/`、`docs/ios/evidence/lane-09/`，包括 picker views、source normalization、insertion orchestrator、private writer／editor mocks、failure UI／tests／證據。

**禁止寫：** `WorkspaceKitIOS` writer／bookmark／scope、`EditorKitIOS` executor、MarkdownCore、Mac `App/AppState+ImageAssets.swift`／image authority／cleanup、AppIOS App state／shell／authoring、PreviewKit、所有 manifest／project／Makefile／CI、共用契約、`agent.md`／Decision Log 和其他 tests。新 package dependency 及 test target registration 均交 C0；首版用系統 PhotosUI／UIKit／UTType 能力。

## Provider／consumer 契約與既有風險

**消費 06：** `IOSWorkspaceAssetWriting`，輸入來源、授權 destination 與 captured context；**只有在 destination coordinated persistence 完成後**才回傳 `IOSStagedImageAsset`。result 保留 operation ID、target location、relative path、owned-file identity、grant generation 與 commit／rollback token；final validation、terminal action／disposal 同樣由 06 協調。不要把 `URL` 可讀寫、bookmark 解出 URL 或 path containment 當作授權仍有效的全部證據。

**消費 04：** `@MainActor IOSSourceEditorControlling` 捕捉 snapshot、提交 `IOSAuthorizedEdit`；最後文字修改必須同 document identity＋revision＋selectionGeneration＋accessGeneration＋可寫且非 composing。**消費 C0／13 提供平台支援的 MarkdownCore：** `SmartPaste.imageInsertion(relativePath:)` 與 `MarkdownImageAssetPolicy` 的路徑格式／10 MiB raster policy。

**提供 10：** picker entrypoint、可注入 writer/editor 的 feature flow、typed progress／failure state；具體外形依 `contracts.md`，不要定義與 root 衝突的 public result。

Mac 現有 `EditorImageAssetInsertion` 使用 validate／commit／discard，`MarkdownTextViewCoordinator+Input.swift` 兩次 revalidate context，再同步 native commit。`App/EditorImageAssetAuthority.swift` 保護 destination namespace 與 leaf identity。這些為 safety 參考；舊 `WorkspaceImageAssetStore.place` 本身不是 iOS file-provider transaction，不能直接搬來 bypass 06。

## 實作順序與交易規則

1. Entry point 提供 Photos 與 Files 單張圖片選擇；首版一次一張，避免自行發明 partial batch acceptance。授權不完整時先顯示選擇資料夾入口，由 06 scope flow 取得權限，沒有 grant 不保存也不改 source。
2. **觸發 picker 前**捕捉 current editor snapshot、document identity/revision、selectionGeneration／accessGeneration、替換 range 和 06 destination authority。UI dismissed／async import 後仍使用這個 context；不能改成最新文件 context 來「幫使用者完成」。
3. Photos source 使用系統 picker 的資料傳輸，無需掃描整個相簿。PNG／JPEG／GIF／WebP 符合共用 policy；Photos 的 HEIC representation 轉成 PNG，再按產物實際 bytes 驗證，不能只改副檔名。其他不支援 representation 拒絕；Files 中 SVG／可執行或不支援格式拒絕，內容與 type 必須符合，不以 filename 單獨判定。
4. 在 off-main 工作取資料／必要 raster conversion，不堵住 UIKit。傳入 06 writer 後由其負責 `assets/` 相對目錄、唯一檔名、不覆寫既有檔、scope retention、destination containment 和 namespace 驗證。本 lane 不重做这些 I/O 策略。
5. 取得 `IOSStagedImageAsset` 後，把它的已保存相對路徑經 `SmartPaste.imageInsertion` 轉為插入字串；使用 capture 的 range 產生 `MarkdownEditResult`，selection 落在插入尾端。空／非法結果不能插空語法。
6. 06 先 final validate staged asset 的 captured destination grant／generation／owned leaf；await 返回後再在 MainActor 檢查當初 document/revision/selectionGeneration/accessGeneration、`canWrite` 和 composing 狀態。以 capture 的 proposal 同步提交 guarded edit，不可 await 後先 `session.text +=`。04 executor 同步重驗，不能只依 UI 按鈕 enabled 狀態；final apply 之前的 root/access 變化必須先使 generation 失效。
7. **Editor accepted：** 只此時 terminal commit staged asset；native source edit 為一次 Undo，Redo 能重新顯示圖片。Undo 不刪圖片，避免 Redo 引用失效。**拒絕／cancel／error：** terminal rollback staged asset，由 06 對確定自己擁有的檔案協調 disposal。
8. 重複 callback／task cancellation／view teardown 都只走一次 terminal action。rollback 失敗或 ownership 不明時保留 recovery state 與相對路徑，提示圖片已保存但未插入，不能用 URL 猜測後 delete。既有 file／他人 namespace occupant 不删除。
9. writer return 與 guarded apply 中間有新的 editor edit／selection／文件／权限變化：零 source mutation，走 rollback／recovery；不排自動 retry，也不悄悄插到新的 caret。圖片可重新選取／重試，但必須取得新 context。

**單一文件情境：** grant 只到 Markdown file 時不能假設 sibling `assets/` 可寫。顯示資料夾授權需求；06 證明該 selected document 位於授權目錄後才啟用 import。取消 grant 保留來源與 selection，沒有 Undo entry。

## 測試與驗收

用可暫停的 writer fake／terminal spy 加 native controller fake；在明確 barrier 間改变狀態，勿以 sleep 猜 race 時序。

| 測試族群 | 必須證明 |
|---|---|
| `IOSImageInsertionOrderingTests` | source edit 晚於 persistence 成功；editor accepted 後 commit 一次，source insertion 使用已保存的相對路徑而非 picked URL。 |
| `IOSImageInsertionStaleTests` | 保存中切檔／同版本異文件／native edit／selection ABA／access generation／composing／read-only／conflict／destination grant 失效時零 source edit，rollback 一次；writer 返回後的 root/namespace replacement 也必測。 |
| `IOSImageInsertionTerminalTests` | cancel、picker dismissal、view teardown、重複 completion、apply rejection、rollback error；不 double commit／rollback，不刪不可證明所有權的檔。 |
| `IOSImageInsertionPolicyTests` | 10 MiB 邊界、轉碼後超限、mismatched extension/type、PNG/JPEG/GIF/WebP、SVG／invalid bytes、空 result／不合法 path、HEIC conversion。 |
| `IOSImageInsertionPathTests` | 空白、括號、Unicode、`#?<>` 檔名由 SmartPaste 正確表示；writer 選的 dedup path 被原樣使用；不由 UI 拼絕對 path。 |
| 04／06 integration | 一次 Undo／Redo 保留已保存圖片；未下載／離線／唯讀／provider error／scope 失效／namespace change；確定 failure 不損來源。 |

module tests 不替代 06 的 filesystem ownership／coordinator tests；引用其 passing exact head，別重做假證據。用真機驗證 Files／iCloud、Photos 與 composing 期間開 picker；preview 顯示只有在 07 同 root 安全存取與 asset refresh 接好後才能宣布 through-path 通過。

## 必須停下與 PR 證據

- frozen writer 沒有 persistence／rollback ownership 證據、單檔權限无法證明 destination、格式 policy 要擴大、需修改源契約／writer／native executor：停該路徑並交 C0 最小 case。不得用 permissive copy／delete 或直接 source append 繞過。
- PR 提供 exact head、transaction time-line、barrier race cases／named test count、accepted／rejected／recovery outcomes、04/06 contract compatibility、尚待 M0 真機與真 provider gate；module／integration／device 結果分開。

## 可直接交給另一個 LLM 的提示

> 執行本 handoff 的 09，最低 L4，分支 phase3-ios-image-insertion。先讀 docs/ios/README.md、contracts.md、agent.md；只寫 AppIOS/Features/Images、AppIOSTests/Images 與 lane-09 證據。使用 06 的 IOSWorkspaceAssetWriting→IOSStagedImageAsset，coordinated persistence／destination final validation 成功才可向 04 IOSSourceEditorControlling 提交 IOSAuthorizedEdit；同 document/revision/selectionGeneration/accessGeneration、可寫且非 composing 才接受。accepted 才 commit，其他 terminal path rollback／保留 recovery；Undo 不刪圖片。04/06 未完成可用 private 同契約 mock；依 ctx7 查實 PhotosUI/UIKit API，完成 deterministic stale／rollback／policy tests，分開 module 與真機 Files/iCloud 驗收，不碰 Mac 或其他 lane，不合併自己的 PR。
