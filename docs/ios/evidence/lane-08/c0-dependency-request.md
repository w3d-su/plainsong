# Lane 08 → lane 13 dependency request

日期：2026-10-08。請求者：lane 08。沒有附帶 Swift diff，因為這些項目屬於 C0 的檔案所有權。

## 現況

`IOS_BASE_SHA` 未公布。`AppIOS` hosted test target 不存在。若現在把 handler 寫進 `AppIOS/Features/Authoring`，就要麼參考不存在的型別，要麼在本 lane 複製 `IOSSourceEditorControlling`。兩者都違反 `docs/ios/contracts.md` §8。

## 請 13 在 C0 提供

1. **單一可編譯宣告**，欄位語意與 `docs/ios/contracts.md` §2 相同：`IOSSourceEditorSnapshot`、`IOSAuthorizedEdit`、`IOSEditOutcome`、`IOSEditRefusal`、`IOSDocumentIdentity`、`IOSDocumentRevision`，以及 `@MainActor IOSSourceEditorControlling` 的 `captureSnapshot`、`apply`、`reveal`、`undo`、`redo`。本 lane 只消費，不另宣告。
2. **`IOSAuthoringAction` seam**，給 10 安裝。本 lane 需要能表達：穩定 id、標題、accessibility label、可空的快捷鍵（key 與 modifier）、放置位置（toolbar、toolbar group、format menu、find）。快捷鍵是資料。請不要在這個型別上附帶「安裝到 `UITextView`」的行為。Descriptor 的具體清單見 `source-investigation.md`，由本 lane 在 IOS_BASE 之後填值。
3. **`AppIOS` hosted test target**，編譯 `AppIOS/Features/Authoring/**` 與 `AppIOSTests/Authoring/**`，可以 `import MarkdownCore`。本 lane 不修改 `project.yml`、Makefile 或 CI。Target 名稱請寫進更新後的 ledger，避免本 lane 自建 scheme。
4. **MarkdownCore iOS platform**。既有 pure API 足夠：`MarkdownEditing`、`Frontmatter`、`EditorFindSession`、`EditorReplacePlanner`、`EditorReplaceContinuationPlanning`、`EditorReplaceSourceConstruction`、`ExactSourceText`、`TextSearchEngine.maximumPatternUTF16Length`。不要求改 planner 行為。
5. **Refusal case 清單**，讓測試能區分 source changed、selection changed、access changed、marked text、read only、invalid range、busy。命名以 C0 為準。

## 刻意不要求的變更

- 不要求把 `TextSearchInputValidation` 改成 public。iOS 分類會用已公開的三個條件：`isEmpty`、`contains(where: \.isNewline)`、`utf16.count > TextSearchEngine.maximumPatternUTF16Length`。這與 Mac `useSelectionForEditorFind` 相同。空結果與 invalid 分開顯示。若 13 希望只有一個分類函式，請在 C0 加公開 API 並升契約版本；本 lane 不會自行改 MarkdownCore。
- 不要求 Link planner 新增 URL 參數。非空選取的 URL 插在 planner caret。空選取只在 planner 骨架正好是 `[]()` 時填入 sheet 的 label 與 URL。仍是一個 `MarkdownEditResult`。
- 不要求 editor 或 `DocumentSession` 的新欄位。Selection ABA 與 access ABA 用既有 generation。

## 13 公布基準之後本 lane 才做的事

從公布的 IOS_BASE_SHA 重建 `phase3-ios-authoring-tools`。只新增：

- `AppIOS/Features/Authoring/**`
- `AppIOSTests/Authoring/**`
- `docs/ios/evidence/lane-08/**` 的實作結果

Private fake 放在測試目錄，同步執行 `apply`。然後跑 `named-test-design.md` 的五個 class，並把指令與結果寫回證據。M0 未過之前，證據維持 module 與 product 分列，不把 fake 綠燈寫成真機通過。

## 失敗案例（給契約審查）

若 `IOSAuthorizedEdit` 只有 `version: Int` 而沒有 `documentID`，同 version 的兩份文件會通過檢查。請保持 `IOSDocumentRevision` 的兩個欄位都參與 `apply`。

若 `reveal` 在 `hasMarkedText` 時仍移動選取，Replace 的 select-only 路徑會打斷中文 composing。請讓 marked text 的 reveal 回 `false` 且 selectionGeneration 不變。本 lane 的 handler 在 snapshot 已標示 marked text 時也不會呼叫它。
