# Plainsong

[English](README.md) | 繁體中文

一款原生 macOS Markdown/MDX 編輯器，以 Swift 打造（SwiftUI 外殼 + AppKit/TextKit 2
編輯器核心）——延續 Typora 的精神，專為部落格寫作流程調校
（Astro/Next.js 內容資料夾、YAML frontmatter、對中日韓文字友善）。

**狀態：公開 Alpha。** 版本未簽署，發佈在
[GitHub Releases](https://github.com/w3d-su/plainsong/releases)。「功能」列出的項目都已在
`main` 上；已發佈的版本可能還沒包含最新的幾項。

## 功能

- **原始碼編輯器：** 以語法剖析器為 Markdown、YAML frontmatter、程式碼區塊與 `.mdx` 中的
  JSX 上色。內建清單接續、成對符號自動補齊、表格格式化與核取方塊切換。
- **即時預覽：** 與編輯器並排，雙向捲動同步。GFM、KaTeX 數學式、Mermaid 圖表與程式碼
  上色都已內建，離線也能使用。
- **檔案：** 可開啟單一檔案，或開啟資料夾作為工作區並使用檔案樹（新增、重新命名、搬移、
  丟到垃圾桶）。支援自動儲存、另存新檔，檔案在磁碟上被改動時會顯示提示列。
- 文件內的**尋找與取代**，以及跨資料夾的**工作區搜尋**（⇧⌘F）。
- **自動補全：** 程式碼片段、連結與圖片路徑、標題錨點、程式碼區塊語言、frontmatter 鍵、
  emoji 短碼，以及 MDX 元件名稱。
- **圖片與連結：** 貼上或拖入圖片時，會複製到 `assets/` 並插入連結；在選取的文字上貼上
  網址會變成連結。
- **Frontmatter 檢閱器**（⌃⌘I）：日期、標籤與草稿有對應的專用控制項。
- **匯出**為自含式 HTML 或 PDF，以及**列印**（⌘P）。
- **主題：** 兩款內建編輯器主題、可匯入的 JSON 配色主題，以及系統、淺色、深色預覽配色。
- **預設保護隱私：** 在沙盒中執行、不收集遙測資料；除非在設定中開啟 **Allow remote images**，預覽不會從
  網路載入任何內容。

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
- **編輯器配色主題** 可從 設定 ▸ 編輯器 匯入。主題是一份 JSON 色盤（僅接受 `#RRGGBB` 或
  `#RRGGBBAA`；文字、游標與背景必須不透明）。匯入的主題會與 Plainsong、Graphite 分開
  列出。預覽仍使用內建的系統、淺色與深色配色。不支援使用者 CSS 與個別字型設定。
- **預覽圖片** 支援不超過 10 MiB 的 PNG/JPEG/GIF/WebP，以及不超過 1 MiB、通過結構檢查後
  僅以圖片方式顯示的工作區 SVG。不支援 `data:` SVG、行內 `<svg>`，以及 HTML/PDF 匯出中的
  SVG；遠端 SVG 交由 WebKit 處理，不會經過驗證。
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
- **更新：** `v0.1.0-alpha.5` 之後的 release 可透過 Sparkle 在 App 內更新。
  alpha.1–alpha.5 沒有更新程式，請手動安裝下一版一次。第二次啟動時 Plainsong 會詢問
  是否自動檢查更新；隨時可用 **Plainsong ▸ Check for Updates…** 手動檢查。
  「自動下載並安裝」預設關閉（Settings ▸ General）。預發佈版本（如 `v0.9.0-beta.1`
  這類 tag）只在開啟 **Receive beta updates** 時才會提供，使用 beta 版請記得開啟。
  版本未經簽署：更新後 macOS 可能會再次要求你確認開啟 Plainsong。

## 授權

Copyright © 2026 w3d-su.

Plainsong 是自由軟體：你可以依照自由軟體基金會發佈的
[GNU 通用公共授權條款](LICENSE)第 3 版，或（依你的選擇）任何更新的版本，重新散布或修改它
（SPDX：`GPL-3.0-or-later`）。散布本軟體是希望它有用，但不提供任何擔保，也沒有適售性或特定
用途適用性的默示擔保。詳見 [`LICENSE`](LICENSE)；授權條款以英文原文為準。

macOS 編輯器連結了 [STTextView](https://github.com/krzyzanowskim/STTextView) 2.4.1，其作者
允許開放原始碼 App 以 GPLv3 使用它
（[`docs/third-party/STTextView-2.4.1-LICENSE.md`](docs/third-party/STTextView-2.4.1-LICENSE.md)），
因此 Plainsong 採用 GPL。先前的版本，包括 `v0.1.0-alpha.5` 及更早的所有 release，以 MIT
授權發佈，仍可依 MIT 授權使用。

App target 另外連結 [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.0。
Release 版本會將 `PLAINSONG_UPDATES_ENABLED` 設為 YES；其他版本不會建立更新程式，
也不會發出任何更新請求。所有更新來源與下載檔都會以 App 內的 EdDSA 公鑰驗證。Sparkle 為 MIT，並包含
bsdiff、sais-lite 與 orlp/ed25519；聲明見
[`docs/third-party/Sparkle-2.10.0-LICENSE.txt`](docs/third-party/Sparkle-2.10.0-LICENSE.txt)。

意見回饋與錯誤回報：[GitHub Issues](https://github.com/w3d-su/plainsong/issues)。
本 App 不收集任何遙測資料；Alpha 版本以直接下載方式發佈
（見 [`docs/release-engineering-plan.md`](docs/release-engineering-plan.md)）。
