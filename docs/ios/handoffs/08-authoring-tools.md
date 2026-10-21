# 08 — 格式工具列、Frontmatter、尋找與單次取代

## 任務與智力需求

建立 iOS 寫作工具，重用 MarkdownCore 的格式、Frontmatter、literal Find 與單次 Replace 規劃；所有來源修改經已授權的 editor executor。首版沒有 workspace search、regex、Replace All 或 WYSIWYG。

| 項目 | 要求 |
|---|---|
| 最低智力 | **L3／高** |
| 原因 | 要整合多個已測試的純 planner、處理 form draft／Find generation／UTF-16 selection，同時嚴守 editor mutation 入口；native Undo／IME／檔案寫入安全由 L4 lanes 實作。 |
| 分支 | `phase3-ios-authoring-tools` |
| 一個 PR 的終點 | 可注入 editor fake 的 authoring views／handlers／tests；10 能組装到手機／平板 shell。 |

先讀 [協作總覽](../README.md)、[共用契約](../contracts.md)、`agent.md`。歷史盤點基準為 `main b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`；實際開工從 C0 契約凍結 commit。

## 依賴與可同步範圍

- C0／13 凍結 `IOSSourceEditorControlling`、`IOSAuthorizedEdit`、editor snapshot 與 `IOSAuthoringAction` descriptors 的 consumer seam，並提供 MarkdownCore iOS 平台支援；descriptors implementation 屬本 lane，01 僅為 M0。
- 04 editor 未完成時使用同契約 private fake，可同步完成 form／planner／拒絕路徑。不要自行加替代 native editor、public fallback protocol 或另一份 session。
- 10 shell 負責放置本 lane 的 views、安裝 action descriptors／外接鍵盤 shortcuts，並路由到 current editor。04 只負責 native typing 與 Undo／Redo dispatch。
- **Module-ready 與 M0 integration-ready 分開。** fake pass 不等於真機中文鍵盤、焦點、Undo 或 VoiceOver 通過；M0 未關閉前不宣布完整产品寫作流程驗收通過。

## 檔案所有權

**只准本 lane 寫：** `AppIOS/Features/Authoring/`、`AppIOSTests/Authoring/`、`docs/ios/evidence/lane-08/`，包含 toolbar／panel／find view、handlers、由純結果產生 `MarkdownEditResult` 的本地 adapter、private protocol fake 與 tests／證據。

**禁止寫：** AppIOS 入口／App state／shell／workspace／images、任何 package／manifest、Mac `App/Views/FrontmatterPanel.swift`／Find、`project.yml`／Makefile／CI、共用契約、`agent.md`／Decision Log、其他 tests／fixtures。C0 先提供 hosted test target；缺 target 時提交 registration 要求，不能自行新增另一個 scheme。

## Provider／consumer 契約

**提供 10：** `IOSAuthoringAction` descriptors 與 authoring views。Format／Find 的 action、標題、accessibility label 與快捷鍵依凍結契約定義；本 lane 不在 UITextView 上重複安裝 key commands。

**消費 04：** 在 MainActor `captureSnapshot()`，產生帶 `baseRevision`、`selectionGeneration`、`accessGeneration`、`undoActionName` 的 `IOSAuthorizedEdit`，要求 `IOSSourceEditorControlling.apply`。reveal 操作帶 expected revision，也走同一 editor。**消費 C0／13 提供平台支援的 MarkdownCore：** `MarkdownEditing.apply`、`Frontmatter`、`EditorFindSession`、`EditorReplacePlanner`、`EditorReplaceContinuationPlanning`。

禁止直接 `DocumentSession.replaceText`、`UITextView.text =`、改 App 的 source binding，或以「更新 UI」先發布來源。accepted outcome 才讓上層 session／預覽／儲存進行；rejected outcome 保留 user draft，提示重新確認，不自動把舊命令重送到新文件。

## 實作要求

### 格式與工具列

- 常用列提供 Bold、Italic、Link、Heading、Code；其餘放 Format menu：Strikethrough、Inline Code、Paragraph、Quote、Code Fence、Inline/Display Math、Checkbox、Format Table。使用現有 `MarkdownEditCommand`／`MarkdownFormattingCommand`，不重新實作 toggle／list／table／math 演算法。
- Link 等需要 sheet 的命令，在啟動時保留 editor snapshot；使用者完成輸入後仍用當初 revision／selectionGeneration／accessGeneration 提交。檔案、選取或存取狀態變了就拒絕，保留表單文字，不改另一份文件。
- 對不適用的 math／table command 使用既有 planner 的 nil/refusal 行為；提供可見／accessible 說明，沒有 edit 或 Undo。composing、read-only、conflict／unavailable document 的 enablement 由 canonical snapshot 決定；executor 最後仍重驗。
- 外接鍵盤 descriptors 以 repo 既有語義為準：⌘B、⌘I、⌘K、⌘1…6、⌘0、⌘⇧Q、⌘⇧K、⌘L、⌥⌘F、⌘F、⌘G／⇧⌘G、⌘E 使用選取 Find。Inline Code 不佔用 ⌘E。

### Frontmatter

- 面板從當前來源推導，使用 `Frontmatter.parse`；string、calendar date、tags、bool 使用 type-aware control，`.raw`／複雜 YAML 欄位先唯讀。沒有 block 時提供 `Frontmatter.insertingDefaultBlock`；缺結束 fence／malformed YAML 顯示 raw＋error，不修復或重寫。
- 欄位編輯用 local draft；按完成／Return 確認一次，toggle 變更也形成一個 guarded edit。保存 capture 的 document／revision／selectionGeneration／accessGeneration；外部變更時仍保留 draft，重新讀 source 後由使用者再次確認。
- 使用 `Frontmatter.updating`，保留其 string quoting、unknown keys、CRLF／LF 行為。將 old／new source 的最小連續變更轉為 `MarkdownEditResult`；UTF-16 prefix/suffix diff 不切 surrogate/composed sequence，依 frozen snapshot 保留／映射 selection，不能把整份字串直接丟入 source binding。
- diff 前後選取：在 replacement 前保持位置；在 replacement 後平移 delta；與 replacement 相交則收在新片段末端。所有 range 做 overflow／boundary 檢查；對來源完全相同的 form 操作不發布 revision、不增 Undo。
- UI 只有 editor 接受後重新 derive source；不能用 optimistic `textSnapshot = updatedText` 蓋過較新文件。回寫一次 Undo 還原原 YAML，Redo 再套用。

### Find／單次 Replace

- 首版 literal Find；預設 `.smart`，提供 `.sensitive`／`.insensitive` 與 whole-word 選項。使用既有 query validation：空字串為 empty state，換行或超過 256 UTF-16 顯示 invalid state；不把「無結果」和「query invalid」混為一談。
- 非同步 search 的 result 帶 query generation＋文件 identity/revision；新的 query、文件、source revision 立即淘汰舊 result。只保留一個最新 pending，不能讓 1 MB 搜尋占 main actor。使用 `EditorFindSession.search`，保留上限 10,000 並以既有 10,001 probe 標記 truncated；UI 計數显示 `10,000+`，不做第二個自訂 probe。
- Next／Previous 用既有 session navigation；快速連按需保留步數，不被 async search 合併成一次。用 `stepped(by:)` 處理待完成計算的 net intent；不同 document/query generation 不繼承 intent。
- Replace 必須針對已揭露且正好選取的 currentMatch；若當前 editor selection 不是該 match，該次 action 只 reveal／select，零 source mutation。下一次 action 重新 capture／plan／guard，再以 match 的實际 UTF-16 range 作替換，不能用 query 字串長度推算。
- 使用 `EditorReplacePlanner.planOneMatch`；replacement 不含換行且 ≤256 UTF-16。空 replacement 可以删除；literal-identical replacement 不 edit、不增 Undo，依 `afterLiteralIdentical` 繼續；真修改後用 `afterOneReplace` 重掃，沒有後續 match 時 `currentOrdinal = nil`，不自動 wrap。Next／Previous 仍可明確 wrap。
- 搜尋欄／replacement 欄獲 focus 不等於 source selection 改變；handler 保留 current editor 的原選取證據，不能拿 form 本身的文字當成 Find selection。

## 測試與驗收

| 測試族群 | 必須證明 |
|---|---|
| `IOSAuthoringGuardedEditTests` | 各 action 使用單一 guarded route；舊 revision／異文件同版本／selection ABA／access generation／composing／read-only／conflict 拒絕後零 mutation。 |
| `IOSFormattingActionTests` | 空／跨行／繁中／emoji selection、nested toggles、math refusals；action label、newSelection、一次 Undo 指令契約；shortcut 不重複 dispatch。 |
| `IOSFrontmatterPanelTests` | literal strings、引號、Unicode／换行、tags／date／bool、unknown keys、CRLF、malformed YAML；draft race 不覆寫新來源，no-op 不發布。 |
| `IOSFindGenerationTests` | 延遲舊 query/source/doc result 被丟棄；快速 Next 步數正確；Unicode canonical equivalence／case fold 導致 match 長度不同時仍以 actual range reveal。 |
| `IOSSingleReplaceTests` | first action select-only、guard rejection、empty replacement、literal-identical no-op、一次真正 edit、256／257 boundary、truncated session、post-replace 無自動 wrap。 |

module tests 使用 fake 記錄 calls 與拒絕後狀態，不能只 assert UI labels。04／10 接起後，記錄 source／selection／Undo before/after 的 hosted 驗證；正式中文候選字與 VoiceOver／hardware keyboard 留真機腳本。執行 C0 指定 iOS target checks、受影響 MarkdownCore named tests、lint 與 `git diff --check`。

## 必須停下與 PR 證據

- planner 行為要改、需要新增 canonical field、无法以现有 editor protocol 保留 selection／single Undo、需碰 package／shell：交具體 contract／dependency request 給 C0，停該部分；不另造 mutation 路徑。
- PR 提供 exact head、descriptor 清單、fake 驗證與真实 integration 驗證分開、negative stale probes、仍待真機／IME／無障礙項目、10 要安装的 view/action inputs。所有未達成 gate 維持 open。

## 可直接交給另一個 LLM 的提示

> 執行本 handoff 的 08，最低 L3，分支 phase3-ios-authoring-tools。先讀 docs/ios/README.md、contracts.md、agent.md；只改 AppIOS/Features/Authoring、AppIOSTests/Authoring 與 lane-08 證據。重用 MarkdownCore；所有格式、Frontmatter 和單 Replace 都 capture 同一 editor snapshot，再由 IOSSourceEditorControlling apply IOSAuthorizedEdit，保留 identity/revision/selectionGeneration/accessGeneration。只提供 IOSAuthoringAction descriptors，10 安裝快捷鍵；不改 editor 或 session。以 private fake 可同步開發，保留 draft／query generation／UTF-16／拒絕零變更，完成 named tests 和 PR 證據；M0 真機 gate 未通過不能宣布 product-ready，不合併自己的 PR。
