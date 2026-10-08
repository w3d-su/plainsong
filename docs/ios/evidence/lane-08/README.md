# Lane 08 — 格式、Frontmatter、Find／單次 Replace：交付摘要

日期：2026-10-08。契約版本：IOS-C0-v1（specification，尚未實作）。推理等級：L3。

## 狀態宣告

**C0 尚未交付，本 lane 沒有可編譯的 authoring 實作。** 2026-10-08 再次 `git fetch origin` 後，`origin` 只有 `main`（`b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`）、`phase3-ios-parallel-handoffs`（`2144c46c888360c84a42fef79e676e60b518048b`）與 lane 10 的調查分支。`docs/ios/integration-ledger.md` 仍寫 `IOS_BASE_REF`／`IOS_BASE_SHA` 為 Not published。Repo 沒有 `AppIOS/`、`EditorKitIOS`、`IOSDocumentContracts.swift` 或 hosted iOS test target。

`docs/ios/README.md` 規定基準未公布時只做來源調查與測試設計，不從 `main` 另寫一套 contracts。`docs/ios/handoffs/08-authoring-tools.md` 規定實際開工從 C0 契約凍結 commit，缺 hosted test target 時提交 registration，不自建 scheme。因此這裡沒有 `IOSSourceEditorControlling`、`IOSAuthorizedEdit`、`IOSAuthoringAction` 的第二份宣告，也沒有 private fake 的 Swift 原始碼。Named tests 只以設計存在，**沒有編譯、沒有執行、沒有 PASS**。

M0 真機 gate 未通過。本文件不宣布 module-ready，也不宣布 product-ready。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-authoring-tools` |
| 調查基準 | `2144c46c888360c84a42fef79e676e60b518048b`（handoff packet）。**不是 IOS_BASE_SHA**。實作 worktree 等 13 公布可抓取的 IOS_BASE_REF 與完整 SHA 後重建 |
| Head | 本分支 tip。以 `git rev-parse phase3-ios-authoring-tools` 為準 |
| PR | Draft，base 為 `phase3-ios-parallel-handoffs`，只含本目錄。不對 `main` 開 PR：packet 仍在 draft PR #153，對 `main` 的 diff 會混入 13 的規格檔。實作 PR 等 IOS_BASE_SHA |
| 實際修改路徑 | `docs/ios/evidence/lane-08/**` |
| 已實作介面 | 無 |
| Doubles | 04 editor、05 document binding、10 shell 安裝點都未接。Private fake 留在測試設計，未寫成原始碼 |
| Named tests | 設計見 `named-test-design.md`。未執行 |
| 未跑的檢查 | 無 AppIOS target，故未跑 iOS `xcodebuild`、SwiftLint、SwiftFormat、`swift test`。`git diff --check` 只覆蓋本目錄的 Markdown |

## 文件索引

- [`source-investigation.md`](source-investigation.md) — 可重用的 MarkdownCore／Mac 行為，以及 iOS adapter 必須守住的呼叫點。
- [`named-test-design.md`](named-test-design.md) — 五個指定測試類型的方法、fixture、斷言與失敗反例。
- [`c0-dependency-request.md`](c0-dependency-request.md) — 交給 13 的 registration。沒有這些宣告就不能開始寫 `AppIOS/Features/Authoring`。

## 關卡分列

- **已關閉：** 無。
- **待 C0：** hosted test target、`IOSSourceEditorControlling`／`IOSAuthorizedEdit`／snapshot／`IOSEditRefusal` 的單一可編譯宣告、`IOSAuthoringAction` seam、MarkdownCore 的 iOS platform 設定。
- **待本 lane 在 IOS_BASE 上實作：** toolbar／Format／Frontmatter／Find views、單一 guarded route、private fake、五個 named test class。
- **待整合：** 04 真實 editor 的 source／selection／Undo before-after；10 安裝 descriptors 與外接鍵盤，不在 `UITextView` 上再掛一套 key commands；05 的 read-only／conflict 要先推進 access generation。
- **Owner-only 真機：** 注音／拼音 composing 期間格式與 Replace 被拒、硬體鍵盤快捷鍵只觸發一次、VoiceOver 能讀到 math／table refusal 與 invalid query、Frontmatter draft 在檔案外部變更後仍在。

## 不做的事

- 不改 editor、`DocumentSession`、Mac Find／Frontmatter、任何 package、`project.yml`、Makefile、CI、`agent.md`、Decision Log、integration ledger、其他 lane。
- 不提供 workspace search、regex、Replace All、WYSIWYG replace。
- 不 merge 自己的 PR，不 force-push，不改 owner checkout `/Users/davis._.su/Documents/blogeditor`。
