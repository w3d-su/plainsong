# 02 — 共用 SyntaxKit 與 Mac 相容層

## 任務與智力需求

把目前 EditorKit 裡的純語法解析抽成 `SyntaxKit`，同時供 Mac 與 iOS 使用；維持 Mac 原有語義 token、可視範圍、fold plan、link/image region 與樣式結果。iOS 首版只消費 source-mode token，不啟用 WYSIWYG。

| 項目 | 要求 |
|---|---|
| 最低智力 | **L4／最高** |
| 原因 | 同時處理跨 package 存取、tree-sitter 狀態隔離、UTF-16 offset、可視範圍 context，以及 Mac fold/reveal 相容；看似純搬檔可能破壞 Mac Replace 和 IME 的呈現證據。 |
| 分支 | `phase3-ios-syntax-kit` |
| 一個 PR 的終點 | 共用 package、Mac 相容 adapter、iOS 可編譯的純解析 API，附語義／fold differential 證據；不含 iOS editor 或 UI。 |

先讀 [協作總覽](../README.md)、[共用契約](../contracts.md)、`agent.md`。歷史盤點基準為 `main b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`；實際開工以 C0 公布的契約凍結 commit 建獨立 worktree，不能自行發明另一版契約。

## 依賴與可同步範圍

- C0／13 先提交共用 request/result 外形、package skeleton 與 MarkdownCore iOS 平台支援。01 是 M0 真機 spike，並非核心 portability 作者。
- 契約凍結後，可與 03 WorkspaceCore、04 UIKit editor、05 文件 I/O、07 preview 同步。04 可先以固定 token fake 開發，不能反向修改這條 lane 的解析器。
- 解析／Mac 相容層的 module 開發可先完成；**M0 真機 gate 未通過前，不得宣布完整 iOS 產品整合或 IME／效能驗收通過**。本 lane 的 Mac regression 仍是必須通過的 gate。

## 檔案所有權

**只准本 lane 寫：**

- 新 `Packages/SyntaxKit/` 的解析 implementation、純 model、tests 與 package-local manifest；C0 已凍結的契約檔除外。本 lane 在 C0 之後獨占 `Packages/SyntaxKit/Package.swift` 與既有 `Packages/EditorKit/Package.swift`，兩份 manifest 的抽取變更需與搬檔在同一分支，維持可建置。
- `Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxParser*.swift`、`WYSIWYGFoldParser*.swift`、`WYSIWYGFoldModel.swift` 的搬移與相容 adapter。
- `Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxHighlighter.swift` 中消費共用解析结果所需的變更；保留 AppKit theme/font/presentation mapper。
- 由 `Packages/EditorKit/Sources/TreeSitterTSXFixed/`、`TreeSitterYAMLFixed/` 搬至 SyntaxKit 的既有 vendored grammar source。搬移時保留內容、license 與 attribution，不順手升版 grammar。
- `Packages/EditorKit/Tests/EditorKitTests/MarkdownSyntaxHighlighterTests.swift`、`WYSIWYGFoldModelTests.swift` 中相容性驗證所需變更；其他 Mac 測試先只讀與執行。
- `docs/ios/evidence/lane-02/`：本 lane 的 rationale、對照輸出與驗證證據。

**禁止寫：** `MarkdownCore`、`EditorKitIOS`、`App/`、`AppIOS/`、`WorkspaceKit*`、`PreviewKit`、`preview-src`、其他 lane 的 tests／fixtures。全域 `project.yml`／Makefile／CI、`agent.md`／Decision Log 和共用契約由 C0 整合；交付具體修改清單給 C0，不在自己的 PR 偷改。

## 目前來源與必須維持的契約

- `MarkdownSyntaxParser.swift` 現在雖只 import Foundation／MarkdownCore／grammars，卻位於 AppKit package；token 是 internal type，含 heading level、frontmatter、table、MDX/TSX 種類。
- `WYSIWYGFoldParser.swift` 與 `+Inline.swift` 是同一 mutable parser 的 extensions。`WYSIWYGFoldModel.swift` 為純模型；只抽 `tokens(in:)` 而遺留無法取用 parser 的 extensions 會破壞 Mac production path。
- `MarkdownSyntaxHighlighter.swift` 的 `MarkdownHighlightService` actor 同時產生 attributed fragment 與 fold plan；高亮／fold 使用同一次 parse 的關係需保留。AppKit 的 `NSFont`、`NSColor`、fold attributes 留在 EditorKit。
- `EditorHighlightScheduler.swift` 已採單 runner、最多一個 pending request，解決 final highlight 遺失。這次不改其 lifecycle 或 UI 排程。

**提供 04 與 Mac adapter：** 依 `contracts.md` 的 `SyntaxRequest`、`SyntaxResult`、`MarkdownSyntaxTokenizing`，保留每個 semantic kind 與**整份來源的絕對 UTF-16 range**；result 原樣回傳 requestID／version 與 coveredRange。consumer 自己將 requestID 綁定到當時文件 identity／viewport／generation；requestID 不代表檔案授權。不得把顏色、字型、`AttributedString` 或 UIKit／AppKit 物件放入純 syntax API。

**消費 C0／13 提供平台支援的 MarkdownCore：** `FileKind`、來源字串與既有純 Markdown／image region model。tree-sitter `Parser`／`Tree`／`Node` 必須困在同一串行 executor／actor；外部只取得 immutable Sendable 值，不用 `@unchecked Sendable` 把可變 parser 穿過 actor。

## 實作順序

1. 先用既有 Fixtures 與 Mac tests 建立可審查的 baseline：token kind、range、排序，以及 fold region／image region／revealed 狀態。移動前後比較結果，不改 parser 演算法來讓測試改綠。
2. 抽出純 token、viewport context、MDX/TSX/YAML injection、fold model／resolver 與 parser implementation。以最小相容 adapter 保留 Mac 既有呼叫方式；所有純型別只能依賴 Foundation／MarkdownCore／既有 grammar。
3. grammar 和 SwiftTreeSitter 使用目前 pinned dependency；本 lane 在同一分支改兩份 package manifest，移除 EditorKit 對 moved C targets 的重複編譯並加入 SyntaxKit dependency。不可出現同一 grammar symbol 被兩個 targets 重複連結。
4. 保留目前 viewport expansion：整行、最低 context、frontmatter、跨 viewport code fence；fragment token offset 轉回绝對位置。保留 token 的 location 升序、同位置 length 降序，以及非法／空 range 過濾。
5. Mac attributed styling 在原 facade 執行。維持 nested bold/italic/link 的作用順序和 fold/source mode 的差異；iOS 呼叫同一純解析器但不要求 fold presentation。
6. 更新套件範圍的 API 文件，寫明座標單位、結果有效範圍、失敗回傳與 cancellation 的限制。模組型別外形以 C0 契約為準；需要新公開欄位時先提出 contract amendment。

**具體限制：** 現在 `nsRange(for:)` 使用 tree-sitter byte range 除以 2；需確認目前 SwiftTreeSitter parse input 的 UTF-16 編碼並保留正確換算，不可改成 UTF-8 byte offset。保留 full-document convenience API 現有 cutoff 行為；250 KB historical cutoff 不能被當作 iOS 可視上色效能通過的證據。

## 測試與驗收

| 測試 | 必須證明 |
|---|---|
| 純 syntax differential | `kitchen-sink.md`／`.mdx`、`product-page.mdx`，移動前後 kind、絶對 range、順序相同。 |
| Unicode／換行 | 繁中、emoji／surrogate pair、NFD、LF／CRLF、viewport 不在 0；不漂移、不越界、不切壞 composed sequence。 |
| Context boundaries | viewport 起訖位於 YAML、長 fence、TSX、multiline inline markup，空來源／EOF／超界 range 可處理。 |
| Mac fold compatibility | `WYSIWYGFoldModelTests`、`WYSIWYGLinkFoldingGateTests`、`MarkdownSyntaxHighlighterTests`；nested link/emphasis、折疊邊界、圖片 raw metadata 與 source mode 維持。 |
| Mac downstream | 跑既有 EditorKit Replace／highlight scheduler tests；不得為搬 package 弱化揭露證據或 stale presentation 守衛。 |
| iOS／concurrency | iOS simulator compile 不連結 AppKit／STTextView；重複／併發 requests 不交錯 parser 狀態。 |

以 C0 提供的固定命令跑 SyntaxKit unit tests、Mac EditorKit suite 和 iOS compile；記錄命令、commit、named test 數量。檢查 strict concurrency diagnostics、pinned SwiftFormat lint、`git diff --check`。大文件量測要分清純 parser recorded load、Mac regression、iOS 真機 budget；不能由單一 wall clock 值關閉全部效能 gate。

## 必須停下與交付證據

- fold／token differential 不一致、既有 Mac public behavior 需要變更、grammar iOS 編譯不可行、需求需碰禁止路徑：停止該部分，向 C0 交付最小重現與修正選項。保留已完成的純 module 工作。
- 不用刪測試、靜默降級 regex、把所有來源同步 parse 到 main actor 或停用 Mac folds 解決問題。
- PR 必含：對比的 baseline／head SHA、純資料輸出對照、移動清單、Mac regression／iOS compile 分開的結果、未完成真機／效能 gate、C0 必須採納的 manifest 和 Decision Log patch 描述。

## 可直接交給另一個 LLM 的提示

> 執行本 handoff 的 02，共用 SyntaxKit 抽取；最低 L4。先讀 docs/ios/README.md、contracts.md、agent.md，從 C0 契約凍結 commit 建獨立 worktree，分支 phase3-ios-syntax-kit。只改本文件允許路徑；維持 Mac tokens、fold/image region、樣式與 Replace 呈現守衛，純 API 回傳 semantic kind＋絕對 UTF-16 ranges。不可改全域 manifest 或契約。依當前 AGENTS.md 的 ctx7 規則查實用到的第三方 API；執行上述 differential 和 Mac regression，交付可審查 PR 與分開的 module／真機 gate 證據，不合併自己的 PR。
