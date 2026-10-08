# Lane 08 named tests

C0 提供 hosted target 與凍結型別之後，測試放在 `AppIOSTests/Authoring/`。Fake 是該目錄的 private type，同步實作 13 凍結的 `IOSSourceEditorControlling`。它記錄 `capture`／`apply`／`reveal`／`undo`／`redo`、拒絕原因，以及拒絕後的 text、selection、selectionGeneration、accessGeneration、undo 次數。Fake 不存在第二個 public protocol。

下列方法是要實作的完整名單。斷言寫成可直接轉成 `XCTAssert` 的條件。在 IOS_BASE 落地前，這些測試 **沒有檔案、沒有執行結果**。

`IOSEditRefusal` 的 case 名稱以 C0 凍結宣告為準。設計用這些語意：source／document changed、selection changed、access changed、marked text、read only、invalid range、busy。Case 拼法不同時，只改斷言名稱，不在本 lane 自訂 enum。

## `IOSAuthoringGuardedEditTests`

每個會改文字的 action 都走同一條 `apply`。拒絕之後 text、selection、兩個 generation、undo 次數與拒絕前相同。

| 方法 | 必須證明 |
|---|---|
| `testFormatFrontmatterAndReplaceShareOneApplyRoute` | Bold、bool toggle、真正的 single replace 各呼叫一次 `apply`，沒有直接寫 fake text 的其他方法。 |
| `testStaleRevisionRefusesWithZeroMutation` | Capture 時 version 是 3。`apply` 看到 live version 4 並拒絕。Edit 的 `baseRevision.version` 仍是 3。Text 不變，undo 次數 0。 |
| `testSameVersionDifferentDocumentRefuses` | Sheet 的 documentID 是 A，live editor 是 B，兩者 version 都是 1。Edit 帶 A。拒絕。B 的文字不變。 |
| `testSelectionABARefuses` | Live range 與 capture 相同，`selectionGeneration` 從 5 變成 7。Edit 帶 5。拒絕。Generation 停在 7，selection 不變。 |
| `testAccessGenerationABARefuses` | `accessGeneration` 從 2 變成 4，range 與 version 沒變。拒絕，文字不變。 |
| `testMarkedTextRefusesRevealAndApply` | `hasMarkedText == true` 時，math 選取、Replace reveal、Bold 都不呼叫 `reveal` 或 `apply`。 |
| `testReadOnlyRefuses` | `canWrite == false`。Handler 仍提交原 snapshot 的 edit。Fake 拒絕。Undo 次數 0。 |
| `testBusyRefusalDoesNotRetry` | Fake 回 busy。`apply` 次數是 1，draft 還在，沒有排第二次 `apply`。 |
| `testRejectedLinkDraftIsNotRetargeted` | Link draft 是 `https://example.test`。拒絕後欄位仍是該字串。之後把 fake 換成文件 B，`apply` 次數仍然是 1。 |

## `IOSFormattingActionTests`

預期 edit 來自同一次 `MarkdownEditing.apply`，測試不重算 delimiter。

| 方法 | Fixture 與斷言 |
|---|---|
| `testBoldEmptyCaret` | `"hello"`，caret 5。`apply` 的 result 等於 planner。Undo 名稱 `Bold`。呼叫次數 1。 |
| `testBoldMultilineSelection` | `"a\nb"`，選取覆蓋兩行。Result 等於 planner。 |
| `testBoldTraditionalChineseAndEmoji` | 選取 `「測試😀」`。Result 等於 planner，range 含完整 surrogate。 |
| `testBoldNestedToggleRemovesDelimiter` | 選取已含 `**word**` 的內層或外層，以 planner 的解除結果為準，只 `apply` 一次。 |
| `testItalicStrikethroughInlineCodeQuoteFenceCheckboxTableMatchPlanner` | 每個命令一列。非 nil 就一次 `apply`；quote／paragraph 的 nil no-op 則 `apply` 次數 0。 |
| `testMathRefusalInCodeHasNoEditOrUndo` | 選取在 fenced code 內。Planner 為 nil。`apply` 與 `reveal` 都是 0。Accessible 說明非空。 |
| `testMathInsideFormulaRevealsWithoutApply` | `'$x$'`，caret 在公式內。Planner replacement 為空且 range 長度 0。`reveal` 收到 `newSelection` 與原 revision。`apply` 次數 0。 |
| `testDisplayMathRefusalOnListHasNoUndo` | 列舉行上的 display math 為 nil。Undo 次數 0。 |
| `testLinkSheetSubmitsCapturedGenerationsOnce` | 選取 `docs`，URL `https://example.test`。Edit 的四個 identity 欄位等於打開 sheet 時的 snapshot。Result 的 range 等於 planner range。URL 出現在 planner caret（`(` 之後）。`apply` 一次，名稱 `Link`。套上原文字後是 `[docs](https://example.test)`。 |
| `testLinkEmptyDestinationUsesPlannerResult` | 非空選取且 URL draft 為空。`MarkdownEditResult` 與 planner 相等。 |
| `testLinkEmptySelectionInsertsLabelAndURL` | Caret 在 `hello` 尾端，label `docs`，URL `https://example.test`。Planner 骨架是 `[]()`。一次 `apply` 後該處變成 `[docs](https://example.test)`。 |
| `testLinkUnwrapSkipsSheet` | 選取整個 `[docs](https://example.test)`。一次 `apply`，沒有殘留 sheet draft。 |
| `testLinkCaretOffsetOutsideReplacementRefuses` | 測試替身若觀測到 offset 越界，`apply` 次數 0。正常 planner 不該觸發；這是 adapter 的防禦斷言。 |
| `testUndoActionNameMatchesDescriptorTitle` | Bold、Quote、Format Table 的 `undoActionName` 分別是選單標題。 |
| `testCatalogShortcutIdentifiersAreUnique` | 每個快捷鍵最多一個 descriptor。⌘E 只屬於 Use Selection for Find。Inline Code 的快捷鍵是空的。 |
| `testAuthoringViewDoesNotInstallKeyCommands` | Authoring view 不暴露 `UIKeyCommand`。呼叫 descriptor 一次只產生一次 `apply` 或一次 `reveal`。 |
| `testStrikethroughKeepsControlCommandXUnlessC0NarrowsTheList` | Descriptor 有 ⌃⌘X。此列在 13 明示刪除前保持。 |

Toolbar 還要有一列存在性斷言：Bold、Italic、Link、Heading 群組（level 1…6）、Code 群組（Inline Code 與 Code Fence）。群組本身不是 edit。

## `IOSFrontmatterPanelTests`

Oracle 是 `Frontmatter.updating` 或 `insertingDefaultBlock`。Diff 後的全文必須與 oracle `ExactSourceText.matches`。

| 方法 | 必須證明 |
|---|---|
| `testQuotedLiteralStringRoundTrip` | 值 `say "hello"`。提交後全文等於 `updating(..., .string)`。未知 key 仍在。 |
| `testUnicodeAndEmbeddedNewline` | 值 `測試\n第二行`。全文等於 oracle。Replacement 不覆蓋 frontmatter 之後的正文。 |
| `testTagsDateAndBool` | `.stringList(["a", "b"])`、`.date("2026-10-08")`、`.bool(true)` 各一次 `apply`。Bool 在切換當下提交，不等第二個確認鍵。 |
| `testUnknownKeysAndCRLF` | 原始 block 含未知 key 與 CRLF。Oracle 保留它們。Body 的 CRLF 不在 replacement range 裡。 |
| `testMalformedYAMLShowsRawAndDoesNotRewrite` | `Frontmatter.parse` 的 `error != nil`。畫面有 raw 與 message。`apply` 次數 0。 |
| `testMissingClosingFenceDoesNotRepair` | 只有開頭 `---`。顯示 missing-delimiter error。不補結尾 fence。 |
| `testAbsentBlockInsertsDefault` | 無 frontmatter。`apply` 的結果等於把 `insertingDefaultBlock` 的 diff 套上原文字。日期由測試注入 `2026-10-08`。 |
| `testRawFieldHasNoCommit` | `.raw` 欄位沒有確認動作。`apply` 次數 0。 |
| `testDraftRaceKeepsDraftAndNewerSource` | Draft `新標題` 尚未確認。Live 文字換成 `# other`，version 增加。確認後 fake 拒絕。Draft 仍是 `新標題`，live 文字仍是 `# other`。`apply` 次數 1，且 edit 帶舊 identity。 |
| `testSecondConfirmUsesNewSnapshot` | 上一個拒絕之後，使用者再次確認。新 edit 的 revision 是拒絕後重新 capture 的 revision，不是第一張 sheet 的 revision。 |
| `testIdenticalFormDoesNotApply` | 來源已是 `updating` 的輸出，再用同一 value 確認。`apply`、undo、version 都不變。 |
| `testSelectionBeforeInsideAndAfterDiff` | 舊 `abcd`、新 `abXYZcd`。Range 是 `(2, 0)`，字串 `XYZ`。選取 `(0, 1)` 不變；`(4, 0)` 變成 `(7, 0)`；`(2, 0)` 變成 `(5, 0)`。 |
| `testDiffDoesNotSplitSurrogate` | `a😀b` → `a😁b`。Replacement location 是 1，length 是 2。不是 2 與 1。 |
| `testDiffDoesNotSplitCombiningMark` | `a` + U+0301 → `a`。Range 是 `(0, 2)`，不是 `(1, 1)`。 |
| `testOverflowingSelectionRefuses` | 平移會 overflow 或超出新字串時 `apply` 次數 0。 |
| `testViewDoesNotPaintSourceBeforeApply` | Fake 拒絕時，面板的已接受來源仍是舊 snapshot。Draft 另行保留。 |

## `IOSFindGenerationTests`

搜尋啟動器可注入。預設實作在 caller 返回之後才呼叫 `EditorFindSession.search`。

| 方法 | 必須證明 |
|---|---|
| `testHandlerReturnsBeforeSearchStarts` | 啟動器是掛起的 continuation。`perform` 返回時 search 尚未開始。放行後才搜尋。 |
| `testStaleQueryGenerationDropped` | Generation 1 掛起時送出 generation 2。放行 1 後，畫面上的 session 仍是 2 的結果。 |
| `testStaleSourceRevisionDropped` | 搜尋開始時 version 是 5。完成前 live version 變成 6。結果不發布。 |
| `testSameVersionOtherDocumentDropped` | 結果的 documentID 是 A，完成時 editor 是 B，version 都是 5。B 的計數不變。 |
| `testOnlyLatestPendingSearchIsRetained` | 連續三次 query。Fake 只持有最後一個 task。前兩個的完成回呼不發布。 |
| `testRapidNextUsesSteppedByThree` | 無 current、pending 中呼叫 Next 三次。發布後的 ordinal 等於 `base.stepped(by: 3).currentOrdinal`。 |
| `testStepsResetWhenQueryChanges` | 累積 3 之後改 query。新 generation 的步數是 0，不從 3 開始。 |
| `testEmptyQueryIsDistinctFromNoResults` | `""` 的狀態是 empty，計數為空，`isTruncated == false`。 |
| `testNewlineIsInvalid` | `"a\nb"` 是 invalid，不是「無結果」。不發布 session matches。 |
| `testPattern257IsInvalidAnd256IsSearchable` | 257 個 `a` 是 invalid。256 個 `a` 會進入 search。 |
| `testNoResultsUsesValidQuery` | Query `zzz`，來源 `hello`。狀態是 no results，不是 invalid。 |
| `testCanonicalEquivalenceRevealUsesActualRange` | 來源 `e` + U+0301，query U+00E9，sensitive。Reveal range length 是 match length 2，不是 1。 |
| `testCaseFoldLengthUsesActualRange` | Insensitive query `ß`。Reveal length 等於該筆 `TextSearchMatch.range.length`，測試不斷言它等於 1。 |
| `testFindFieldFocusKeepsEditorSelection` | Editor 選取 `(1, 2)`。焦點進入 find 欄後輸入 `zzz`。記錄的 editor selection 仍是 `(1, 2)`。 |
| `testUseSelectionAdoptsBoundedEditorText` | Editor 選取 `hit`。Query 變成 `hit`，不自動 `next()`。 |
| `testUseSelectionIgnoresNewlineAndOverlongSelection` | 選取含換行，或 UTF-16 長度 257。Query 維持原值。 |
| `testTruncatedCountRendersTenThousandPlus` | `EditorFindSession.search` 對 10,001 個不重疊的 `x`。`total == 10000`，`isTruncated == true`，畫面上有 `10,000+`。Spy 看不到第二個 limit。 |

## `IOSSingleReplaceTests`

| 方法 | 必須證明 |
|---|---|
| `testFirstActionRevealsWhenSelectionIsNotMatch` | 來源 `one two one`，current match 是第一個 `one`，editor 選取在別處。`reveal` 收到該 match range 與原 revision。`apply` 次數 0。 |
| `testSecondActionReplacesActualRange` | Reveal 成功後重新 capture，選取等於 match。`planOneMatch` 成功。`MarkdownEditResult.replacementRange` 等於 `match.range`。字串是使用者的 replacement。`apply` 一次。 |
| `testGuardRejectionLeavesSource` | 第二次 action 的 `apply` 因 selectionGeneration 拒絕。來源仍是舊文字，session 不改走 `afterOneReplace`。 |
| `testEmptyReplacementDeletesMatch` | Replacement `""`。`validateReplacement` 為 `.valid`。`apply` 一次，range 是 match。 |
| `testLiteralIdenticalDoesNotEdit` | Replacement 與 match slice exact-equal。`apply` 與 undo 都是 0。Session 等於 `afterLiteralIdentical`。有下一個 match 時才 `reveal`。 |
| `testOneRealEditRescansWithoutWrapping` | 來源只有 `one`，換成 `two`。`.applied` 後用新 snapshot 文字做 `afterOneReplace`。`currentOrdinal == nil`。 |
| `testFollowingMatchBecomesCurrent` | 來源 `one one`，第一個換成 `two`。Continuation 的 current 是剩下的 `one`，不是第一筆 wrap。 |
| `testNextStillWrapsAfterUnresolvedCurrent` | 上列 `currentOrdinal == nil` 之後按 Next。Ordinal 變成 `next()` 的結果，可以是 1。 |
| `testReplacement256Accepted` | 256 個 `z` 通過並 `apply`。257 個 `z` 是 `.exceedsMaximumUTF16Length`，`apply` 次數 0。 |
| `testReplacementNewlineRefuses` | `"a\nb"` 不 `apply`。 |
| `testTruncatedSessionReplacesRetainedCurrentMatch` | 10,001 個 match 的 session。`planOneMatch` 對 current 成功。`planBatch` 呼叫次數 0。UI 仍是 `10,000+`。 |
| `testQueryLengthIsNotMatchLength` | NFD 來源、NFC query。Replacement range length 等於 match length，不等於 query UTF-16 count。 |
| `testMarkedTextSkipsRevealOnSelectOnlyReplace` | `hasMarkedText`。`reveal` 與 `apply` 都是 0。 |

## 實作後要補的證據

IOS_BASE 上的實作 PR 要另附：

- 上述 class 的指令與通過數量。
- Private fake 的拒絕呼叫紀錄，不是只有 label 斷言。
- 04／10 尚未合併時，hosted editor before／after 列為未跑。
- 真機中文候選字、VoiceOver、硬體鍵盤列為未跑。
