# 01 — M0 真機可行性驗證

先讀 [協作總覽](../README.md)、[凍結契約 C0](../contracts.md) 和根目錄 `agent.md`。此任務是獨立原型與證據；目前 macOS 文件中的 iOS non-goal 由已核准的 iOS 計畫取代，其他架構規則仍有效。

## 任務與智力需求

- **目標：** 在 iPhone／iPad 真機證明 UIKit TextKit 2 輸入、Files／iCloud 權限、背景儲存和自行簽名安裝可行，建立產品接線前的 M0 關卡。
- **最低智力：L4。** 需要區分 native 輸入事件、marked text、選取／Undo、非同步呈現、File Provider 和生命週期之間的因果關係。只會做畫面或修到測試綠燈的模型不足以解釋資料遺失風險。真機候選字與簽名安裝仍須 owner 操作；模型能力不能替代硬體證據。
- **分支：** `phase3-ios-m0-device-spike`；從協調者指定的 base SHA 建立專屬 worktree，勿修改 owner checkout。
- **可立即開始：** 原型不依賴其他實作 lane；可與凍結介面、mock、核心抽取和測試撰寫同步進行。

## 檔案所有權

| 可修改 | 用途 |
|---|---|
| `Prototypes/iOSM0/**` | 獨立 `project.yml`、原型來源、原型測試、資源與原型專用建置入口／README。 |
| `docs/ios/evidence/m0/**` | 情境清單、去識別化真機結果、失敗重現與 M0 結論。 |
| `docs/ios/handoffs/01-m0-device-spike.md` | 本任務交接文件。 |

不得改根 `project.yml`、`Makefile`、`Scripts/ios/**`、App／套件產品碼或其他 lane 的測試。原型可以讀取已凍結的共用介面，但不得把原型補丁直接接進產品。原型專案生成檔與 build artifacts 留在自身目錄或指定暫存目錄，不手改 `.xcodeproj`。

## 依賴與 C0 契約

- 接受 C0 的文件身分＋revision、UTF-16 source range、呈現無文字修改、儲存基準與衝突保護規則；原型證據以相同語意命名，不能另建矛盾的政策。
- 13 Integration lane 提供正式 scaffolds／C0 freeze；M0 不等待 scaffolds 才開工，也不擁有正式 target bootstrap。
- 04 Editor、05 Document I/O、06 Workspace access、07 Preview、10 App shell 在 C0 凍結後可先用 mock 實作；**接上正式編輯、外部文件儲存與背景生命週期前，必須取得 M0 真機 PASS**。未通過只能保留獨立實驗與 mock 接線。
- 12 Build lane 產出正式 unsigned IPA；M0 先驗證原型 IPA 自行簽名安裝，再由 12／13 對正式 IPA 重跑安裝與開檔關卡。兩者不能互相替代。
- 所有 SDK／CLI 具體寫法在實作時依使用者 `ctx7` 流程及 Apple 原始文件確認；不要拿 macOS bookmark entitlement 或 API 直接當 iOS 行為證據。

## 執行規格

1. 建立最低 iOS／iPadOS 26、iPhone＋iPad 的獨立原型：原始碼 editor、只改呈現的非同步上色、source／selection／revision／Undo 探針、文件／資料夾選擇器、最近文件權限恢復、dirty／saving／conflict 可見狀態。
2. 探針記錄實際 `markedTextRange` 與候選字期間的事件；無 marked text 時才能執行會重設文字或選取的操作。讓過期上色在文件切換和新 revision 之後返回，證明被拒絕且 source／selection／Undo 不變。
3. 使用測試專用 Files 本機資料夾及 iCloud Drive 資料夾，分別測單一文件和資料夾權限；關閉重啟後解析 bookmark。無資料夾授權時只可處理已授權單檔，圖片／相關文件須額外授權。
4. 儲存按文件序列化：故意阻塞 revision N 儲存後再輸入 N+1；N 成功只能推進已持久化基準，N+1 仍 dirty。外部版本變更時，乾淨文件載入；dirty 文件保留本地內容與復原稿，暫停覆寫。
5. 執行退到背景、進前景、系統中止後重啟、File Provider 暫時不可用、離線、唯讀與外部搬移／刪除情境；未完成的儲存不得假稱成功。復原稿須可讀回，不能只是顯示成功訊息。
6. 產出原型 arm64 Release unsigned IPA，由 owner 自行簽名／安裝。記錄實際簽名方式與安裝結果，不保存憑證、帳號或 profile；安裝後再驗證文件選擇器與授權文件讀寫。

同一台 Mac 的 Xcode build、simulator／device run、UI 與計時量測必須共用 `PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`。參考 `Scripts/run-export-html-e9.sh` 的 `lockf` 及靜機准入，不改原腳本；每次原型執行持有同一把鎖，未取得鎖回報排程等待。可以平行寫程式，不能平行啟動模擬器測試。

## 測試與停止關卡

| 關卡 | 必要情境／通過證據 |
|---|---|
| M0-IME | iPhone＋iPad 的繁體中文注音／拼音：建立候選字、選字、修改組字、刪除、跨行選取、emoji／ZWJ、貼上及 Undo／Redo；記錄來源 UTF-16、選取、marked text 和 Undo 結果。程式呼叫 `setMarkedText` 只能當補充。 |
| M0-Presentation | 新字輸入、文件切換、上色完成、preview／editor 切換與視窗尺寸變更後，無額外 user edit、source 差異、selection relocation 或 Undo entry。 |
| M0-Files | 真實 Files／iCloud File Provider：選檔與選資料夾、未下載文件、bookmark 恢復／失效、離線、唯讀；錯誤明示且內容可復原。 |
| M0-Save | 阻塞舊儲存＋新編輯、dirty 外部更新、背景／中止復原；沒有較舊快照回寫或未授權覆寫。 |
| M0-Install | owner 自行簽名的 IPA 在真機啟動、Files 開檔、修改和重新載入成功；僅 archive／zip 成功不能通過。 |

- 任一內容遺失、組字破壞、額外 Undo／選取修改或未授權覆寫，標記 **FAIL／禁止產品接線**，保留最小重現與完整因果鏈。不得用 disable guard、無限 retry 或放寬 safety policy 換 PASS。
- 沒有真機、provider 或簽名安裝證據時，標記 **OPEN owner gate**；模擬器或單元測試可通過，但 M0 不可 PASS。
- 找到問題時提出 C0 修訂需求給 13／協調者；不得在原型 lane 自行改正式介面。

## 交付與 reviewer 驗收

交付一個原型 PR：能重現的原型命令、情境對照表、結果 JSON／Markdown、允許公開的截圖或錄影連結，以及 `PASS / FAIL / OPEN` 結論。證據必填 source SHA、Xcode／SDK、裝置型號與 OS、測試文件 SHA-256、操作順序、起訖時間、期望／實際來源與選取、當時 dirty／saving／conflict 狀態。不得存 raw bookmarks、私人 URLs／文件、裝置完整識別碼或簽名資料。每次 rerun 保留獨立結果，不覆蓋失敗嘗試。

本機、自動測試、真機 owner 證據分開列；PR 綠燈不得關閉真機欄。Claude／reviewer 應能只靠交接與證據重現失敗，且每個 PASS 都指向確切裝置執行。完成後向 13 回報 M0 狀態，不自行 merge 或發布 App。

## Evidence（由執行者填寫）

尚未執行；本文件沒有原型、真機組字、File Provider 或自行簽名安裝通過證據。

## 可直接貼給 agent

```text
請執行 Plainsong iOS 的 01 M0 真機可行性 spike（L4 極高推理）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/01-m0-device-spike.md。使用獨立 phase3-ios-m0-device-spike worktree，只寫 Prototypes/iOSM0 和自己的 evidence。這條線可在 C0 前開始，不修改正式 packages 或 App target。驗證 UIKit TextKit 2 中文 IME／Undo、Files／iCloud 文件與資料夾、背景儲存和未簽名 IPA 自行簽名後啟動。分列 simulator tests 與 owner 真機證據；硬體／簽名未提供時交付可重跑原型和 manual checklist，不假稱 PASS、不繼續完整 App 接線。遵守共享 Xcode 鎖，不自行 merge、force-push 或修改 owner checkout。
```
