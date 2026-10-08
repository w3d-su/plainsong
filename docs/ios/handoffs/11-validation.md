# 11 — iOS 驗收、生命週期與效能證據

先讀 [協作總覽](../README.md)、[凍結契約 C0](../contracts.md) 和 `agent.md`；本 lane 驗證組裝後的行為，不接管模組實作。

## 任務與智力需求

- **目標：** 建立可重跑的 iPhone／iPad 驗收 harness、跨模組 smoke 與真機證據矩陣，證明首版寫作流程及內容保護契約。
- **最低智力：L3；race／IME 歸因由 L4 協助。** L3 可建立穩定測試、負向場景和量測；區分過期 callback、marked text、Undo／選取與 File Provider 的因果鏈需要 L4。不能以最終畫面正確或 rerun 綠燈當根因解釋。
- **分支：** `phase3-ios-validation`，使用獨立 worktree。可與功能開發同步撰寫 harness／fixtures，正式 PASS 等各依賴合入後的整合 head。

## 檔案所有權

| 可修改 | 用途 |
|---|---|
| `IOSAcceptanceTests/**` | UI／launch-test harness、Support、Resources、Performance 情境和必要的去識別化測試資料。 |
| `docs/ios/evidence/validation/**` | 驗收矩陣、手動腳本、測試與效能證據、失敗歸因。 |
| `docs/ios/handoffs/11-validation.md` | 本任務交接文件。 |

讀取既有 `Fixtures/**` 和 `App/Resources/preview/**`，不要修改它們或 Mac 的 `AppTests`、`PerformanceTests`、`PlainsongUITests`。Editor／Document／Workspace／Preview／MarkdownCore 的 package regression tests 由各模組 owner 修改。App 的 DEBUG injection／accessibility identifier 與量測 probe 需求交給 13 或相應功能 owner；target、resources 和 scheme wiring 交給 12，不能偷偷修改產品碼使測試成立。

## 依賴與 C0 契約

- C0 freeze 與 13 scaffolds 後可用 mock 撰寫情境；04 Editor、05 Document I/O、06 Workspace access、07 Preview、08 Authoring（Frontmatter／Find／Replace）、09 Images、10 App shell 的正式整合需透過 13。
- 01 M0 真機關卡是正式產品接線前置；12 的 `ios-build`／`ios-test` 及 test target wiring 是執行 harness 前置。M0 證據可重用為前置證明，不代替最終產品真機驗收。
- 只使用 C0 的 document identity＋revision、UTF-16 selection、單一 native edit／Undo、儲存結果及 conflict／recovery 狀態。DEBUG 導入點須只用合成 fixtures、預設關閉且 Release 不可被開啟。
- 接受 preview `renderID`、asset-root token 和原 source revision 的既有 stale-drop 政策，不以每份文件 version 彼此比較；測試須覆蓋兩份文件同 version 的切換。

## 驗收與 harness 規格

1. 優先少量穩定端到端路徑：launch → fixture → type → source／dirty → preview → save → reopen；iPhone 用切換模式，iPad 寬版用並排，窄視窗用切換。旋轉、窄寬變更及 editor／preview 切換應保留 source、selection、Undo 與文件身分。
2. 合成 launch-test 資料由 `IOSAcceptanceTests/Resources` 擁有；透過協調者核准的 DEBUG seam 導入。每次使用獨立暫存 root 與租約，清理只能移除本次擁有資料，不讀寫使用者最近文件或真實工作區。失敗保留測試資料與對應 head。
3. 以來源文字、UTF-16 選取、revision、Undo 和持久化結果作斷言；UI 等待用有界 predicate／明確 receipt，避免固定 sleep、重試直到綠燈和只斷言元素存在。
4. 在既有 read-only fixtures 上驗證 preview：`kitchen-sink.md/.mdx`、`product-page.mdx`、`math.md`、`math-edge-cases.md`、`broken-frontmatter.md`、`mdx-syntax-error.mdx`。測試圖資用本 lane 合成小 PNG，不依賴個人目錄或網路。
5. 跑測前先列舉 bundle 必需資源、非空內容和 SHA-256；借鑑 `PerformanceResourcePreflight` 的檔案存在／權限／內容檢查，不直接搬 macOS bundle 路徑。缺資源即 fail before timing，不能把 skip 當量測通過。
6. 全部 Xcode build、UI、simulator／device 與 wall-clock 量測透過 12 的固定鎖入口：`PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`。同一台 Mac 只跑一組，source writing 可同步。12 已取得鎖時不重入另一個取鎖 wrapper。

## 測試矩陣與關卡

| 分類 | 必驗情境／關卡 |
|---|---|
| Editor | 注音／拼音真實候選字、emoji／ZWJ、貼上、跨行選取、硬體鍵盤、格式與單次取代一次 Undo；上色／preview completion 無額外文字修改或 selection／Undo 改變。程式組字測試不替代真機。 |
| Session／Save | N 儲存阻塞後輸入 N+1、切檔時舊成功／失敗返回、dirty 外部修改、background／termination recovery；舊 success 不得標記 N+1 clean，衝突不得覆寫。 |
| Files | 本機與 iCloud Drive、未下載、離線、唯讀、bookmark 失效、外部搬移／刪除及 Mac／iOS 同時修改；復原稿能重新讀回，重新授權入口可用。provider 真實語意須 owner 真機補證。 |
| Tools | Frontmatter 型別及 literal round-trip、錯誤 YAML 保留原文；Unicode Find／single Replace、過期 match、無 selection／document authority 的零修改拒絕；圖片取消／write failure 無文字插入，單檔缺資料夾授權不擅讀 parent。 |
| Preview | Markdown／MDX、table、fence、Mermaid、math、placeholder、MDX error 保留 last good DOM；舊 render／asset root 不得污染新文件；離線可用。 |
| Security | 遠端圖片預設關閉、script／event／style／SVG sanitizer、`..`／symlink／obsolete asset token／oversize asset 拒絕；錯誤不得放寬根目錄權限。 |
| Accessibility | iPhone／iPad、直橫向、iPad 窄寬視窗、VoiceOver 可達性與焦點順序、硬體鍵盤核心操作。不能用 simulator screenshot 宣告真機輔助使用通過。 |
| Performance | 真機 `perf-100kb.md` 與 `large-1mb.md`：輸入呈現 p95 <16 ms、可視上色 <50 ms、100 KB preview render <100 ms，150 ms debounce 另計。資源／機器准入、樣本數、原始樣本及統計方法完整。 |

Performance：每裝置／fixture 先 warm-up，再至少 60 次固定位置與內容的輸入；在鍵入可視呈現、parser／visible highlight 和 WebKit render completion 各自標記時間，記錄 C0 revision／renderID。只量 `textDidChange` callback 或字串修改耗時不能叫 input-to-screen。儀器不能量到可視畫面時保留 OPEN，記錄可量測項目而不改名冒充。

裝置別記錄 thermal state、low-power mode、OS、build configuration 和背景負載；明顯節流或其他 Xcode／simulator work 同時進行時不做效能結論。Hosted CI 和 simulator 的 performance 為診斷資料；owner 真機 idle 門檻才是產品驗收。1 MB fixture 同時驗證資料正確與回應性，不擅自把 100 KB preview 目標套到所有大小。

## 失敗處理與交付

- 提供模組 owner：最小 fixture、確切 head、named failing test、受控步驟、期望／實際、event／revision timeline；修復由 owner 在自己的檔案完成，本 lane 補跨模組回歸。
- 單次 fail 後保留每次 rerun 嘗試。若後來通過，原 failure 的原因與關卡狀態仍須說明；不可用改 timeout、skip 或重跑抹掉未知 race。
- 交付驗收 PR、required-resources manifest、手動裝置 checklist、每 head 的結果索引、logs／xcresult 位置、raw timing samples、環境與 fixture hashes。大檔用受控 artifact 路徑與校驗碼，不 commit cache／DerivedData／個人檔案、raw bookmarks／私人 URLs／簽名資料。
- 狀態分成 **local automated / exact-head hosted / owner device & manual / performance**，每個項目標 `PASS / FAIL / OPEN / BLOCKED` 並連證據。`ios-test` exit 0 必須核對實際執行的 named tests／sample counts；零測試或所有案例 skipped 是失敗。
- Claude／reviewer 需能用 12 的固定入口重跑。所有首版驗收通過後回報 13；reviewer／owner 處理 merge，lane 不自行發布／簽名。

## Evidence（由執行者填寫）

尚未執行；本文件沒有 iOS 自動驗收、真機、效能或無障礙通過證據。

## 可直接貼給 agent

```text
請執行 Plainsong iOS 的 11 跨模組驗收（L3 高推理，race／IME 歸因需要 L4）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/11-validation.md。從公布的 IOS_BASE_SHA 建立 phase3-ios-validation worktree，只修改 IOSAcceptanceTests 和自己的 evidence；target wiring 交 12，production composition 交 13。先寫 deterministic barriers／fixtures／manual scripts，providers 到位後測 exact integration head。驗證 stale saves／asset reads／image rollback、iPhone／iPad、中文、鍵盤、VoiceOver、100KB／1MB 效能，分開 mock、simulator、真機和 CI 證據。使用共享 Xcode 鎖；不弱化測試以換綠燈，不自行 merge 或改其他 lane。
```
