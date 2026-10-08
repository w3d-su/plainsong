# 13 — C0、共同基準、整合與 release gate

## 任務與智力

**L4 極高。** 要審核跨模組 source／revision／grant／native Undo 的 authority，維護依賴與單一檔案作者，判斷 mocking、CI 與真機各能證明什麼。此角色是整合者與 gate owner，不把某線的未實作 provider 當作產品功能。

分支：`phase3-ios-integration`。先讀 `agent.md`、[README](../README.md)、[契約](../contracts.md)及 01–12 handoffs。本任務分 C0 與後續 composition/release 兩個可審查 PR；不能在 C0 偷接整個產品。

## 所有權

- 永久擁有：新增 MarkdownCore iOS contracts／platform support、`WorkspaceKitIOS/Package.swift`、所有 frozen `Contracts.swift`／PreviewAssetReading 表面、`AppIOS/App/**`、`State/**`、`Composition/**`、`AppIOSTests/Integration/**`、`agent.md`、Decision Log、此包總表／contracts、integration ledger。
- C0 暫時擁有最小 skeleton manifests 與 `project.yml`／Makefile bootstrap。C0 完成後明確交接：02 SyntaxKit＋Mac EditorKit manifests；03 WorkspaceCore＋Mac WorkspaceKit manifests；04 EditorKitIOS manifest；07 PreviewKit manifest；12 global project／Makefile／Scripts/ios／ios.yml。WorkspaceKitIOS manifest 仍由 13 獨占。
- 不修改另一線的產品原始碼來掩蓋未完成工作；向 owner 回傳具體錯誤／最小修復要求。處理 merge conflicts 可以改合併結果，但保留各線語意與 evidence，要求相关 owner review。
- 01 prototype 與 owner device data、其他 Mac worktree 均不在可修改範圍。

## 第一個交付：C0（先做，所有線共用）

1. Live fetch `main`，獨立 worktree，記錄精確 base；本 handoff 包最初基準是 `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`，不能當永久最新 main。
2. 更新 `agent.md`：iOS 成為獨立核准工作線；Mac 原本的核心/UI政策繼續適用。Decision Log 同 commit 記錄本包所有已核准 architecture／ownership choices，讓其他線不需爭改 shared docs。
3. 為 MarkdownCore 補 iOS 26 platform。保留現有 public Mac APIs；使用既有 `rebaseSavedText(to:)`，不為 parallelization 重寫 dirty semantics。
4. 建立 SyntaxKit、WorkspaceCore、EditorKitIOS、WorkspaceKitIOS 的可編譯 package skeleton 與契約宣告。SyntaxKit 只提取 immutable token type 宣告及 seams，真正 parser／pure fold 移動由 02 做；WorkspaceCore 只凍結 portable model surface，Mac tree／physical sidecar extraction 由 03 做。
5. 凍結 contracts.md 中所有 protocol 的精確 Swift declarations（actor、async／sync、events／cancellation、typed errors、identity／generation、success/refusal）。建立只含 private doubles 的 contract smoke consumer tests。04 的 document attach/detach／事件 callback、05 store observer、06 lease/coordination/writer surface、07 reader＋checker signatures 一次定義，其他線不得各自選另一種。
6. 建立 AppIOS skeleton、單一 scene、明確 unavailable 的 composition root、shared preview folder resource 設定與最小 simulator contract tests。C0 不載入 fake document data、不顯示假 save success、不以 unavailable service 演示完整 App。
7. `make generate` 由 project.yml 產生，最低 iOS／iPadOS 26；保留 Mac target／test targets／resources。給 12 明確的全域檔案交接 commit；交接後只 review 不同步修改。
8. 更新 `docs/ios/integration-ledger.md`：契約版本、IOS_BASE_REF／完整 SHA、每線起點與 ownership、C0 named tests、M0 open gates。先建立 draft PR，不自己 merge。若維護者暫不 merge，公布可抓取精確分支＋SHA供 stacked worktrees 使用，明確 PR base。

### C0 可宣布通過的條件

- 同一基準的 package manifests／headers／兩個獨立 consumers 可編譯；沒有 duplicated contract declarations。
- 每線的 exclusive path 和 global ownership 沒有同時 writer；scaffolds 的 future source/test subdir 已被 target 自動納入，避免日後每線都改 manifest。
- Mac 至少 pure package 回歸與 scoped build/lint 通過；全套 Mac CI 與本機結果各自記錄。
- iOS 26+ simulator build／contract smoke 通過。沒有 simulator runtime／設備時可交付 scaffold，但 C0 編譯 gate 維持 open，不能宣布所有線可 release。
- M0 真機／iCloud／重簽安裝維持 open，C0 不關 M0。

## 第二個交付：production composition（M0 + providers 後）

固定接線順序：02／03 → 04／06／07 → 05／08／09／10 → composition → 11／12 acceptance。

- 同一開啟文件只有一個 `DocumentSession`、一个 UIDocument/store writer、一个 editor、一个 WKWebView。13 為 grant/file resource registry 分配 document identity，重複開啟不生成競爭 writer。
- Editor native apply 同步發布到同一 session；純 presentation／外部 clean reload 不能新增 user edit。store save acknowledgement 更新 baseline，不改較新 source。
- document switch／grant revoke／conflict 先提升 generation、取消 pending commands/assets/render，再 attach 新文件。native composing 中的 reload 先 defer；不能靠取消任務代替 completion guard。
- 08 commands、09 images、07 checkbox source edits 共用 04 native guarded writer；不能直接 update session。預覽 relative links 在明確 grant 內解析，外部 links 經 platform opener。
- 圖片 final guard 同時涵蓋 source context、destination grant、operation-owned file，source insertion 後 commit、拒絕後只 rollback owned asset。
- scene/background 使用 05 flush／recovery。UI 只讀 state；不維護 shadow editable source 或全域 current writer。
- doubles 僅留測試；release composition 必須全部是實際 provider。未完成 capability 明確禁用並在 gate 台帳保持 open，不能代碼中的成功 stub 當完工。

在 production PR 開始接線前，01 必須提供真機 IME／Undo、Files／iCloud、background save、owner 重簽 install 的具名證據。若 owner 尚未驗收，可持續收模組 PR／做 tests；將 owner-only gates 列為等待，不能 merge composition 或稱完成首版。

## 最終 gate

- 11 真機矩陣、typing/highlight/render budgets、VoiceOver、keyboard、background／conflict、stale-save／stale-resource／image rollback 的 deterministic tests 通過。
- 12 Release unsigned device IPA + SHA-256 + SDK／head/signing metadata 可重現；owner 的重簽安裝與文件存取另外驗證。
- 共用套件 Mac 回歸、exact-head CI、local tests、owner manual gates 分列。CodeQL informational，不因它拖延可完成工作。rerun green 不得自動歸因某個 race 已修復。
- Claude 複核各 PR 和最終 integration diff。若自動／人工證據有未過項目，列清楚具體限制；不以 mock 替換處理。
- 不 force-push、不 merge 自己 PR、不改 owner checkout、不洩漏 bookmark／private paths／signing credentials。不加入預算外訂閱、會員或雲端 backend。

## 交付格式

第一個 PR 是 C0；後續每次整合維持可審查小批次。台帳記錄每線 branch/base/head/PR、provider vs double 接點、contract版本、named tests、open gates。衝突修復做 additive commits，中央台帳與 Decision Log 保留每條有效 evidence 一次。

## 可直接貼給 agent

```text
請擔任 Plainsong iOS 平行開發的 13 整合角色（L4 極高推理），執行 docs/ios/handoffs/13-integration.md。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md 與所有 lane handoffs。保留 owner checkout，以獨立 phase3-ios-integration worktree 先交付 C0 可編譯契約、package/App target scaffold、唯一檔案所有權和可抓取 IOS_BASE_REF + 精確 IOS_BASE_SHA，建立可審查 PR後交接 shared manifests。其他線之後才依共同基準實作；你維持 central docs/contract與production composition。M0真機關卡未過不能接完整App。不要發假成功provider、不自行merge、不force-push；每次交付分列local、exact-head CI與owner-only gates。
```
