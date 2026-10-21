# 04 — UIKit／TextKit 2 原始碼編輯器

## 任務與智力需求

建立 `EditorKitIOS`：使用原生 `UITextView` 與 TextKit 2，包成 SwiftUI view，連接文件修訂版、選取與 viewport 回報、非同步可視上色、native Undo／Redo 和 Markdown 輸入行為。上層 authoring／image 功能只能透過本 lane 的 guarded editor command route 改文字。

| 項目 | 要求 |
|---|---|
| 最低智力 | **L4／最高** |
| 原因 | UITextView delegate、TextKit 2、native Undo、中文 marked text 與 SwiftUI reconciliation 交錯；要在延遲工作返回後拒絕舊文件／選取，同時不增添 user edit 或撤銷紀錄。 |
| 分支 | `phase3-ios-editor-kit-ios` |
| 一個 PR 的終點 | 可由 fake session／syntax provider 操作並測試的 editor module；有真實依賴後能接 App，真機 IME 另列 gate。 |

先讀 [協作總覽](../README.md)、[共用契約](../contracts.md)、`agent.md`。歷史盤點基準為 `main b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`；開工從 C0 契約凍結 commit 建獨立 worktree。

## 依賴與可同步範圍

- C0／13 提供 `IOSDocumentIdentity`、`IOSDocumentRevision`、`IOSAuthorizedEdit`、`IOSSourceEditorControlling`、跨模組 callback 與可在 iOS 使用的 MarkdownCore。01 僅負責 M0 spike。
- 02 語法服務、05 文件 host 與 13 App binding 可用同契約 fake 暫代；native component／guard tests 可立即同步。不得把 fake 的 local String 當成另一本 product DocumentSession。
- 08 authoring、09 images 的測試可先使用你提供的 fake／public protocol；只由本 lane 實作真正 native mutation executor。
- **Mock/module-ready 不代表 M0 product integration-ready。** 真機注音／拼音候選字、native Undo 和背景／切換驗證需由 M0 留證；simulator 的 `setMarkedText` 類測試只是守衛測試。

## 檔案所有權

**只准本 lane 寫：**

- `Packages/EditorKitIOS/Sources/EditorKitIOS/Editor/`：UIKit view、SwiftUI representable、coordinator、typed behavior、revision／selection binding、native edit executor。
- `Packages/EditorKitIOS/Sources/EditorKitIOS/Presentation/`：UIKit theme mapping、viewport、highlight scheduler、presentation apply。
- `Packages/EditorKitIOS/Tests/EditorKitIOSTests/` 與此新 package 的 `Package.swift`；只能引用 C0 已公布的依賴與契約。
- `docs/ios/evidence/lane-04/`：本 lane 的 race trace、module／真機 gate 證據。

**禁止寫：** C0 所有的 `Contracts.swift`（不論目前放在 package root 或其他路徑）、Mac `Packages/EditorKit/`、`MarkdownCore`、`SyntaxKit`、所有 App／AppIOS feature、`PreviewKit`／`WorkspaceKit*`、全域 project／Makefile／CI、`agent.md`／Decision Log、其他 lane tests。需要 public contract 或 App shortcut wiring 時，把具體變更交 C0。

## Provider／consumer 契約

**提供 05、08、09、10、13：** `@MainActor IOSSourceEditorControlling`；`captureSnapshot()`、同步 `apply(_:) -> IOSEditOutcome`、`reveal(_:expected:) -> Bool`、`undo()`／`redo()`，以 UTF-16 定位。欄位與方法簽名以 `contracts.md` 已凍結版本為準。

`IOSAuthorizedEdit` 消費同一次 capture 的 `baseRevision`、`MarkdownEditResult`、`selectionGeneration`、`accessGeneration` 與 `undoActionName`。接受前同步確認文件身分、版本、selection／access generation、installed binding、`canWrite` 和非 composing；read-only／conflict／grant 失效先更新 access generation。拒絕回傳 `.refused` 且零文字／Undo／selection 變更，不能先改 source 再判斷。

**消費 02：** `SyntaxRequest`／`SyntaxResult` 的純 semantic token／absolute UTF-16 ranges；本 lane 將 requestID 綁定 document identity、version、viewport／presentation generation，結果全部比對後 UIKit 字型／顏色才套。**消費 05／13：** 13 attach 同一份 05 `DocumentSession`，本 lane 的 native writer 成功後同步發布至該 session；05 只觀察 immutable events。binding detach／access 變化由 13 先更新 generation，不允許上層直接把 session source 覆寫 UITextView。

選取變更使用 generation 避免 ABA：使用者離開原選取又回來，相同 range 仍是新的 generation。純 presentation 不應改此 generation。document identity 不可用 URL 或版本號代替，因為切檔／重開都可能得到相同值。

## 實作順序與不變條件

1. 建立原生 view，確認 `textLayoutManager` 可用、實际走 TextKit 2；source mode 不用 `STTextView`、不加入 folds／attachments 或 HTML editing surface。先證明繁中／emoji／貼上／選取／Undo 基本流程。
2. 加入 installed document binding：native 輸入透過唯一 publisher 推進 DocumentSession；每次 text change 只發布一次。避免高頻 source／revision 經 `@Published` 令整個 App 重建；使用既有 text-change stream 與細粒度 callback。
3. 實作 synchronous guarded executor。使用 UITextView 原生 replacement／Undo 路徑，一次格式或 Replace 是一次 Undo；保留 action label、new selection、Redo。不可以整份 `text`／`attributedText` 重設完成使用者命令。
4. 接 MarkdownCore 的 `MarkdownEditing.apply`：list Enter、Tab/Shift-Tab、auto-pair、code fence／table 行為。composing 時走原生輸入，不攔截候選字／marked replacement，也不強行 `unmarkText`。08 負責 `IOSAuthoringAction` format/find handlers；本 lane 負責 typed behaviors 與 native Undo/Redo dispatch，10 shell 安裝 08 descriptors 並指向 current editor。
5. 加入可視範圍回報和 theme mapper；一個串行 parser request、最多一個最新 pending、debounce 與 lifecycle cancellation。不能以單純 SwiftUI `.task(id:)` 重建來承諾 final request 不遺失。
6. 只改 presentation attributes。套用前檢查 identity＋revision＋presentation generation＋target fragment 精確來源；保留選取、scroll、Undo、typing attributes 和其他 feature 所有的 attributes，composing 時延後。
7. 相同 source reconciliation 是 no-op；真正外部 reload 在無 marked text／無 pending mutation 的狀態安裝，清掉舊 presentation cache，設定 revision／generation floor，排一次新 parse。不能要求使用者再打一字才恢復上色。
8. Editor view 隱藏／切為 preview 時保留 installed state、selection、native Undo 與 composition；由容器隱藏／顯示，避免 SwiftUI 條件分支丟掉原生 view。unmount 取消所有 async work，不可在 deinit 後 apply。

## 測試與驗收

所有新測試放 package-local tests；需要 hosted UIKit tests 的 target 設定交 C0，不能自己改 project.yml。測試用 controlled provider／continuation 重現 race，勿靠固定 sleep。

| 測試族群 | 必須證明 |
|---|---|
| `IOSSourceEditorInputTests` | 繁中、emoji、paste、跨行 selection、Enter/Tab／pair／fence；一次 native change 只發布一次 revision。 |
| `IOSAuthorizedEditTests` | 正常格式／單 Replace 一次 Undo/Redo；舊文件、同版本異文件、舊 installation、revision／selection ABA／composing 拒絕且 source、selection、Undo 都零變更。 |
| `IOSHighlightPresentationTests` | 上色只改 attributes；連續上色不增 Undo，選取與 source bit-for-bit 不變；theme／viewport stale 結果被丟棄。 |
| `IOSHighlightSchedulerTests` | 先阻塞舊 parse 再發多個 edits，最後一個必執行；one runner＋bounded pending；隱藏／reappear／unmount；已產生舊结果也不能越過 reconciliation floor。 |
| `IOSReconciliationTests` | 相同 source 不清 presentation；same-length／same-prefix/suffix 不同中段的 reload 重算；不需後續 user edit；composing 時不安裝。 |
| `IOSMarkedTextGuardTests` | synthetic marked text 時 format／image apply／highlight 不干擾；commit／cancel 後恢復並解析最新 source。這不是 actual IME acceptance。 |

使用 100 KB／1 MB fixtures 留 off-main parse 和可視上色 instrumentation。p95 輸入 <16 ms、visible highlight <50 ms 的正式結果需 M0／最終驗收真機量測；simulator wall-clock 只作診斷。

## 必須停下與 PR 證據

- TextKit 2 無法保留 marked text／Undo、native replace 與 session publisher 無法在同一 guarded transaction 保持一致、必須改 Mac editor 或契約：停下該 wiring，提交最小重現和 guard test，交 C0 決策。
- 禁止用 timer 強行回寫 source、關閉中文輸入、清空 Undo 或字串 binding 降級 editor 來通過。
- PR 列 exact head、UIKit tests named count、contract version、fake／真依賴狀態、race trace、未關閉的 M0 actual-IME／device/performance gate，以及 C0 需整合的 hosted target／shortcut wiring。依既有 build lock 逐一跑 Xcode／UI 工作；Mac 回歸由 C0 在整合 commit 驗證。

## 可直接交給另一個 LLM 的提示

> 執行本 handoff 的 04，最低 L4，分支 phase3-ios-editor-kit-ios。先讀 docs/ios/README.md、contracts.md、agent.md；只寫 EditorKitIOS 的 Editor／Presentation／tests／package manifest 與 lane-04 證據，Contracts.swift 由 C0 所有。用原生 UITextView＋TextKit 2，所有 authoring/image mutation 走 IOSSourceEditorControlling 與 IOSAuthorizedEdit，identity/revision/selection/access generation／native Undo／中文 IME 不可退步。02/05/13 未合併時用同契約 fake；M0 未通過只交付 module-ready。依 ctx7 規則驗證用到的 UIKit API，提供 deterministic stale/reconciliation/marked-text tests 與獨立真機待驗收表，不修改 Mac editor，不合併自己的 PR。
