# Lane 08 來源調查

調查基準：`2144c46c888360c84a42fef79e676e60b518048b`。只讀 `Packages/MarkdownCore`、Mac Format menu 與既有 single-replace executor。沒有改這些檔。

## 凍結後必須消費的唯一寫入面

`docs/ios/contracts.md` §2 規定，本 lane 在 MainActor 呼叫：

- `captureSnapshot() -> IOSSourceEditorSnapshot?`
- `apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome`
- `reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool`

`IOSAuthorizedEdit` 帶 `baseRevision`（`documentID` + `version`）、`selectionGeneration`、`accessGeneration`、既有 `MarkdownEditResult`、`undoActionName`。`apply` 在檢查與寫入之間不 await。Rejected outcome 保持 draft，不把舊命令改送到新文件。`reveal` 只選取，不製造 source edit；`hasMarkedText` 時連 reveal 也不呼叫。

這些型別今天不存在。本 lane 不在 `AppIOS/Features/Authoring` 裡宣告它們。

## MarkdownCore 呼叫點

| 用途 | 符號 | 調查時的行為 |
|---|---|---|
| 格式 | `MarkdownEditing.apply(_:to:selection:fileKind:)` | `nil` 表示 planner 拒絕或 no-op。非 nil 的 `MarkdownEditResult` 是唯一 replacement。 |
| 格式命令 | `MarkdownEditCommand.format(MarkdownFormattingCommand)`、`.toggleCheckbox`、`.formatTable` | 演算法留在 `FormattingEditing`、`CheckboxEditing`、`TableEditing`、`MathEditing`。 |
| Link 骨架 | `FormattingEditing` 的 `.link` | 空選取得到 `[]()`，caret 在括號內；有選取得到 `[sel]()`，caret 在 URL 位置；已是完整 link 則還原 label。沒有 URL 參數。 |
| Math | `MathEditing.insertInlineMath`／`insertDisplayMath` | context `.refused`、相鄰 `$`、多行、選取內 `$` 都回 `nil`。既有公式回傳空 replacement、空 range、`newSelection` 指到公式內容。 |
| Frontmatter | `Frontmatter.parse`、`updating`、`insertingDefaultBlock`、`isPlainCalendarDate` | malformed／缺結尾 fence 帶 `error`，`updating` 回 `nil`。`updating` 自己負責 quoting、unknown keys、CRLF／LF。 |
| Find | `EditorFindSession.search`、`stepped(by:)`、`next`／`previous` | `EditorFindLimits.engineMatchLimit` 是 10,001；保留 10,000 且 `isTruncated`。 |
| Query 邊界 | `TextSearchEngine.maximumPatternUTF16Length`（256） | 空字串、含 `Character.isNewline`、UTF-16 長度 > 256 時 `matches` 回 `[]`。分類函式 `TextSearchInputValidation` 是 module-internal。Mac `useSelectionForEditorFind` 用同一組公開條件拒絕採用選取。 |
| Replace | `EditorReplacePlanner.planOneMatch`、`EditorReplacePlanning.validateReplacement` | 空 replacement 合法。256 合法，257 為 `.exceedsMaximumUTF16Length`，換行為 `.containsNewline`。`isLiteralIdentical` 用 `ExactSourceText.matches`。 |
| Replace 續行 | `EditorReplaceContinuationPlanning.afterOneReplace`／`afterLiteralIdentical` | 沒有起點 ≥ `resumeUTF16` 的 match 時 `currentOrdinal = nil`。`next()`／`previous()` 仍會 wrap。 |
| 寫後文字 | `EditorReplaceSourceConstruction.replacedSource` | 公開。只在 `apply` 回 `.applied` 之後用來核對新 snapshot。 |
| Truncation | `planOneMatch` 不看 `isTruncated`；`planBatch` 才拒絕 | 本 lane 不呼叫 `planBatch`，也不自己再打一次 10,001 probe。 |

`MarkdownEditResult` 的 `newSelection` 是寫入後座標。Mac single replace 把 `plan.replacement` 插入 `plan.match.range`（`EditorReplaceExecutor.insertAuthorizedReplacement`）。Match 長度是 engine 的 UTF-16 `NSRange`，不是 query 的 UTF-16 長度。`TextSearchEngine.matches` 已寫明 canonical equivalence／case fold 可以讓 match 比 pattern 長或短。

## 格式命令與快捷鍵

Mac menu（`App/PlainsongCommands.swift`）與 `agent.md` §6.4 的對應，就是 descriptor 資料。10 安裝快捷鍵；本 lane 的 view 不在 `UITextView` 上加 key command。

| 命令 | 標題 | 快捷鍵 | 位置 |
|---|---|---|---|
| `.format(.bold)` | Bold | ⌘B | toolbar + Format menu |
| `.format(.italic)` | Italic | ⌘I | toolbar + Format menu |
| `.format(.link)` | Link | ⌘K | toolbar + Format menu |
| `.format(.heading(level: 1...6))` | Heading 1…6 | ⌘1…⌘6 | toolbar 的 Heading 群組 + Format menu |
| `.format(.inlineCode)` | Inline Code | 無。不使用 ⌘E | toolbar 的 Code 群組 + Format menu |
| `.format(.codeFence)` | Code Fence | ⌘⇧K | toolbar 的 Code 群組 + Format menu |
| `.format(.strikethrough)` | Strikethrough | ⌃⌘X | Format menu |
| `.format(.paragraph)` | Paragraph | ⌘0 | Format menu |
| `.format(.quote)` | Quote | ⌘⇧Q | Format menu |
| `.format(.insertInlineMath)` | Insert Inline Math | 無 | Format menu |
| `.format(.insertDisplayMath)` | Insert Display Math | 無 | Format menu |
| `.toggleCheckbox` | Toggle Checkbox | ⌘L | Format menu |
| `.formatTable` | Format Table | ⌥⌘F | Format menu |
| Find | Find | ⌘F | find chrome |
| Find Next | Find Next | ⌘G | find chrome |
| Find Previous | Find Previous | ⇧⌘G | find chrome |
| Use Selection for Find | Use Selection for Find | ⌘E | find chrome |
| Replace one | Replace | 無 | find chrome |

Toolbar 的 Heading 與 Code 是群組，不是第三個 `MarkdownEditCommand`。Handoff 的快捷鍵句子沒有重寫 ⌃⌘X；它存在於 `agent.md` §6.4。Descriptor 先帶上。若 13 認定 handoff 列表是排他清單，只移除此一快捷鍵，命令仍留在 Format menu。

## 實作落點（2026-10-08）

`IOSAuthoringActionPlacement` 每個 descriptor 只有一個位置。Catalog 因此沒有做成上表的「toolbar 與 Format menu 同時出現」，也沒有把 Inline Code、Code Fence 放進 Format menu（handoff 第 41 行要它們在 Format menu）。Named test `testToolbarContainsPrimaryActionsAndGroups` 要求 Code 群組同時含 `.code`、`.inlineCode`、`.codeFence`，所以這三個只在 `toolbarGroup("Code")`。`.code` 與 `.inlineCode` 都呼叫 `.format(.inlineCode)`，快捷鍵都是空的，都不使用 ⌘E。Bold、Italic、Link 只在 `.toolbar`。Heading 1–6 只在 `toolbarGroup("Heading")`。Strikethrough、Paragraph、Quote、兩種 Math、Checkbox、Format Table 只在 `.formatMenu`。Format menu view 只列出 `.formatMenu`。

Find 預設 `TextSearchCaseSensitivity.smart`，另外提供 `.sensitive`、`.insensitive` 與 `wholeWord`。Mac find bar 只有 smart／sensitive 兩態；iOS 這項以 handoff 的三態為準，因為 enum 已存在，不新增搜尋演算法。

## Adapter 規則（IOS_BASE 之後才寫成程式）

### 同一個 snapshot

格式、Frontmatter 確認、Replace 都是：`captureSnapshot` → 用該 snapshot 的 `text`／`selection`／`fileKind` 呼叫 pure planner → 組成一個 `IOSAuthorizedEdit` → `apply`。Sheet 在打開時留下那一次 snapshot；確認時仍提交那組 `documentID`、`version`、`selectionGeneration`、`accessGeneration`。確認當下若再讀到別的 snapshot，只用來顯示，不用來改寫 edit 的四個欄位。

Enablement 看 canonical snapshot：`nil`、`hasMarkedText` 或 `canWrite == false` 時控制項停用。測試仍直接呼叫 handler，證明 executor 拒絕時零寫入。

### Planner `nil`、空 edit、真正 edit

- `MarkdownEditing.apply` 回 `nil`：不 `apply`、不 `reveal`、不 `undo`。UI 露出固定 accessible 說明「無法在這裡使用這個格式」。不重算 math／table 拒絕原因。
- replacement 為空字串且 range 長度為 0：這是 math 選取既有公式。只 `reveal(newSelection, expected: revision)`。
- 其他結果：一次 `apply`。`undoActionName` 等於 descriptor 標題。Link 見下節。

### Link sheet

Mac `.link` 沒有 URL 參數。空選取的結果是 `[]()`，caret 在 `[` 後面（label）；非空選取的結果是 `[sel]()`，caret 在 `(` 後面（URL）。iOS sheet 仍只提交一次 edit。

1. 打開時 capture。Planner 回 `nil` 就不開 sheet。
2. Planner 若把既有 `[label](url)` 還原成 label，不開 sheet，直接一次 `apply`。
3. 非空選取：sheet 只收 URL。空 URL 提交 planner 原結果。非空 URL 插在 planner caret offset。Offset 超出 replacement 就拒絕，不另算括號。`newSelection` 收到拼接後的尾端。
4. 空選取：sheet 收 label 與 URL。兩者都空則提交 planner 原結果 `[]()`。否則只接受 planner replacement 正好是 `[]()` 的情況，把 label 放進括號、把 URL 放進 `()`。不是這個骨架就拒絕，避免自寫一套 link toggle。
5. 以上都是一次 `apply`，名稱 `Link`。四個 identity 欄位仍是打開 sheet 時的 snapshot。

### Frontmatter

- 來源以 `Frontmatter.parse` 推導。`.raw` 與帶 `error` 的 block 只讀，顯示 raw YAML 與 `error.message`。不呼叫 `updating`，也不補結尾 fence。
- 沒有 block 時，插入使用 `Frontmatter.insertingDefaultBlock(into:date:)`。測試注入固定日期字串。
- string／date／tags 用 local draft，完成或 Return 才提交一次。bool 的切換本身就是一次 guarded edit。
- 預期全文是 `Frontmatter.updating` 或 `insertingDefaultBlock` 的回傳值。再做成最小 UTF-16 diff 的 `MarkdownEditResult`。
- Diff：先取共通 UTF-16 前綴與後綴，前綴與後綴不重疊；再把兩邊收斂到 surrogate pair 與 extended grapheme cluster 邊界。全文相同則不 `apply`、不增加 Undo、不發布 revision。
- 選取：完全在 replacement 之前則不變；起點在 replacement 尾端之後則平移 delta，並檢查 overflow 與新字串邊界；與 replacement 相交則收成新片段尾端的零長度選取。任一 range 越界就不 `apply`。
- `apply` 被拒時保留 draft，面板可以顯示新來源的唯讀對照，但不把 draft 清掉，也不自動再送。UI 在 `.applied` 之後才從新 snapshot 重導欄位。

### Find 與單次 Replace

- 空 query 是 empty state。含換行或 UTF-16 長度大於 256 是 invalid state。合法 query 的 `total == 0` 才是無結果。三者的文案不同。不靠 `matches == []` 反推 invalid。
- 搜尋在 caller turn 之外執行 `EditorFindSession.search`。只留最新一個 pending。結果帶 query generation、`documentID`、`version`。完成時重新讀 snapshot；三者任一不同就丟棄。1 MB 文字走同一條 off-caller 路徑。
- ⌘G／⇧⌘G 在 pending 期間累積有號步數，完成且 generation 仍相符時呼叫一次 `stepped(by:)`。文件或 query generation 改變後步數歸零，不繼承。
- Find 欄位取得焦點不改 editor selection。⌘E 讀 editor snapshot 的選取；空選取、越界、含換行或超過 256 UTF-16 時不改 query。
- Replace 第一次若 editor selection 不是 `currentMatch.range`，只 `reveal` 該 range，不 `apply`。下一次重新 capture、plan、guard，replacement range 用 match 的 `NSRange`。
- `plan.isLiteralIdentical` 時不 `apply`、不 `undo`，用 `afterLiteralIdentical` 前進；有下一個 match 才 `reveal`。真正寫入成功後用新 snapshot 的文字呼叫 `afterOneReplace`。沒有後續 match 時 `currentOrdinal = nil`，不選回第一筆。Next／Previous 仍用 `next()`／`previous()`，可以 wrap。
- 截斷 session 仍可對保留區內的 current match 做 `planOneMatch`。計數顯示 `10,000+`。不呼叫 `planBatch`，不另送 limit。

## 有意義的失敗反例

1. **Selection ABA。** 選取從 range A 改到 B 再改回 A，`selectionGeneration` 已增加。只比較 `NSRange` 會把舊 Link sheet 寫進已回復的選取。Edit 必須帶舊 generation，executor 拒絕，文字不變。
2. **同 version、不同文件。** 文件 A 與 B 都是 version 1。A 的 sheet 若只比較 version，會改到 B。`baseRevision.documentID` 必須參與拒絕。
3. **同 version 的過期搜尋。** A 的 revision 5 結果在切到 B 的 revision 5 之後回來。Identity 不同就丟棄，B 的計數不變。
4. **Match 長度不等於 query。** Pattern `é`（U+00E9，1 個 UTF-16）對上 `e` + U+0301（2 個 UTF-16）。Reveal／Replace range 的 length 是 2。用 pattern 長度會切進 combining mark。
5. **快速 Next。** 搜尋尚未回來時連按三次 Next。完成時必須是 `stepped(by: 3)`。合成一次 `next()` 會少走兩步。
6. **Frontmatter draft。** 使用者打了「新標題」之後，來源被換成另一份正文且 revision 增加。確認要被拒；draft 仍是「新標題」；新正文不變；不會自動用新 snapshot 再送出舊 draft。
7. **Surrogate。** `a😀b` 改成 `a😁b` 時，兩個 emoji 共用 high surrogate。共通前綴若停在 high surrogate 上，diff 會拆開一個 UTF-16 code unit。前綴必須退回 `a` 之後，replacement 覆蓋整個 emoji。
8. **Grapheme。** `a` + U+0301 改成 `a`。共通前綴若停在 base 之後，會只刪 combining mark。前綴要退到 cluster 邊界，replacement 覆蓋兩個 UTF-16。
9. **Identical replace。** 目前選取已經是 match，replacement 與 match 原文 exact-equal。`apply` 次數維持 0，Undo 次數維持 0，session 改走 `afterLiteralIdentical`。
10. **Replace 後不 wrap。** 全文只有一個 match，替換後沒有起點 ≥ resume 的 match。`currentOrdinal` 是 `nil`。另外按 Next 才回到第一筆。
