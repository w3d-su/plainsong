# Plainsong

[English](README.md) | 繁體中文

一款原生 macOS Markdown/MDX 編輯器，以 Swift 打造（SwiftUI 外殼 + AppKit/TextKit 2
編輯器核心）——延續 Typora 的精神，專為部落格寫作流程調校
（Astro/Next.js 內容資料夾、YAML frontmatter、對中日韓文字友善）。

**狀態：開發中。** M0–M5 皆已完成合併，M5 已通過驗收。
M5 的效能與安全強化已完成：PR #15 加入基礎建設，PR #20 量測可見範圍語法上色，
PR #21 量測雙 WebView 下主程序 RSS 記憶體門檻，PR #24/#27 以 MDX
淨化器／資源／SVG 政策結案 issue #17。PR #26 完成設定與主題並結案 #16。
2026-06-25 的最終檢查修正了捲動同步、啟動／開啟最近使用的檔案、MDX 錯誤後的持續更新，
以及即時 MDX 補全彈窗等檢查清單阻礙項目；`docs/m5-checklist.md` 現已全數通過。

Phase 2 的 WYSIWYG 仍屬實驗性質。行內摺疊／顯示機制與原生互動門檻已存在，
但藏在預設關閉的 **WYSIWYG 模式（實驗性）** 設定之後；預設的使用模式仍是純原始碼
以及原始碼＋預覽。若要試用，請開啟 **設定 ▸ 編輯器 ▸ WYSIWYG 模式（實驗性）**，
再從 **顯示方式** 選單（`⌘⇧P`）切換版面；若編輯器機制無法使用，會退回純原始碼模式，
且不會更動原始文字。此模式維持預設關閉，直到
[`docs/wysiwyg-release-checklist.md`](docs/wysiwyg-release-checklist.md)
全數通過前都不會升級為穩定功能。行內連結摺疊，以及資料夾工作區中符合條件的本機圖片縮圖，
僅在該實驗模式下提供；參考式連結、自動連結、不符合條件或單檔模式的圖片、
程式碼區塊自訂片段、表格、Mermaid／數學元件，以及真正的 MDX 渲染，仍維持原始文字或延後處理。

## 安裝（Alpha）

從 [**GitHub Releases**](https://github.com/w3d-su/plainsong/releases) 下載最新的 DMG，
並用附帶的 `.sha256` 驗證（`shasum -a 256 -c Plainsong-*.dmg.sha256`）。

Alpha 版本**未簽署**——目前尚未加入 Apple Developer Program
（擁有者決定，2026-07-02），因此 Gatekeeper 會擋下下載版本的首次啟動。可擇一處理：

- macOS：先嘗試開啟 App 一次，再到
  **系統設定 ▸ 隱私權與安全性 ▸ 強制打開** 允許它，或
- 終端機：`xattr -d com.apple.quarantine /Applications/Plainsong.app`

也可以直接從原始碼建置（需 Xcode 16+），完全略過 Gatekeeper：

```sh
make bootstrap && make build
```

已簽署並經公證的版本，會在發佈計畫的 P1/P2 恢復後推出
（見 [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)）。

## 開發

參與本專案所需的一切資訊（無論是 agent 還是人類）都在
[`agent.md`](agent.md)——架構、分層規則、里程碑路線圖，以及
[決策紀錄](docs/decision-log.md)（由 §18 連結）。撰寫程式碼前請先閱讀 `agent.md`。

實用的規劃與交接文件：

- [`docs/m5-plan.md`](docs/m5-plan.md) — M5 驗收歷程與 Phase 2 進入順序。
- [`docs/codex-handoff.md`](docs/codex-handoff.md) — 可直接給 Codex 使用的目標／子代理提示。
- [`docs/acceptance-matrix.md`](docs/acceptance-matrix.md) — 里程碑門檻與佐證。
- [`docs/risk-register.md`](docs/risk-register.md) — 目前的風險與因應措施。
- [`docs/wysiwyg-design.md`](docs/wysiwyg-design.md) — 已核准的 Phase 2 WYSIWYG 先導設計。

```sh
make bootstrap   # xcodegen、swiftformat、swiftlint、node + npm ci
make build       # 產生 Plainsong.xcodeproj 並建置
make test        # Swift 套件測試 + App 測試 + 預覽 vitest 測試
cd preview-src && npm run typecheck
```

需要 Xcode 16+ 與 macOS 14+。

## 數學式（KaTeX）

行內 `$…$` 與獨立區塊 `$$`（開頭與結尾的 `$$` 各自獨占一行）在 `.md` 與 `.mdx`
預覽中都會以內建的 KaTeX 渲染；` ```math ` 程式碼區塊也會以相同方式渲染。
字面上的錢字號請用 `\$`；不支援 `\(…\)` 與 `\[…\]` 分隔符號。
即時範例：`Fixtures/math.md`。

## 已知限制（Alpha）

- **單檔模式與同目錄圖片：** 沙盒只授權存取你開啟的那個檔案，因此旁邊以相對路徑
  引用的 `asset://` 圖片可能無法載入。請將所在資料夾作為工作區開啟，以取得目錄權限。
- **MDX 元件以佔位卡片呈現**（import 顯示為標籤，JSX 顯示為元件卡片）；元件不會被執行。
- **預覽圖片** 僅限 PNG/JPEG/GIF/WebP，且不超過 10 MiB；不渲染 SVG。
  遠端圖片預設關閉，開啟後也只允許 `https:` 圖片。
- **WYSIWYG 為實驗性且僅限行內元素**（標題、強調／刪除線、行內程式碼、
  清單／引言樣式、行內 `[text](url)` 連結，以及資料夾工作區中不超過 10 MiB 的本機
  PNG/JPEG/GIF/WebP 圖片縮圖）。參考式連結、自動連結、遠端／SVG／單檔模式圖片、
  表格、程式碼區塊，以及 Mermaid／數學式，在編輯器中仍維持原始 Markdown；
  預覽窗格則會完整渲染。
- **超大文件（約 1 MiB）：** 輸入與捲動都能運作，但並非即時。
  每次停止輸入後，預覽只會重新渲染你修改過的區塊；含有連結參考定義或註腳的文件仍會整份重新渲染。
- **側邊欄：** 在 macOS 14–26 上側邊欄為固定寬度。在 macOS 27+ 上可調整寬度
  （220–320 pt），並可用 ⌃⌘S 收合。
- **無自動更新：** Alpha 版本需手動下載。

## 授權

Plainsong 以 [MIT 授權](LICENSE) 開放原始碼。

意見回饋與錯誤回報：[GitHub Issues](https://github.com/w3d-su/plainsong/issues)。
本 App 不收集任何遙測資料；Alpha 版本以直接下載方式發佈
（見 [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)）。
