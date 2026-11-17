# iOS 1.0 實機驗收（I1）

日期：2026-11-15。對象：正式 App `PlainsongIOS`，不是 M0 原型。

這份檢查表把 `docs/release-1.0-scope.md` §3 的 Must 項目合併成一次可以做完的流程，
預估 2–3 小時。每一項都是 **OPEN**，直到在實機上做過並記下結果。模擬器、CI 與
M0 原型的結果都不能代替這裡的任何一項。

它取代 `evidence/validation/manual-matrix.md` 作為實機驗收的入口；那份文件保留為
歷史紀錄。正式的效能量測（60 筆取樣、p95）不在這一輪，屬於後續的 I3。

## 受測版本

| 欄位 | 值 |
|---|---|
| 來源 commit | `0c0e8f28852c896cbfbfb5932ed777170c0c12d8`（`main` `f664c5af` 加上 #269） |
| 未簽名 IPA | `PlainsongIOS-0c0e8f28852c.ipa` |
| IPA SHA-256 | `7952dfe777bc16996f142641128d4f8ee9825878d95d8ff16634d39b45541363` |
| 建置 | Release、arm64、Xcode 27.0、iOS SDK 27.0、最低版本 iOS 26.0 |

換了 IPA 就要重新記錄這張表。#269 以 squash 合併後 `main` 上的 commit 會不同；
這份 IPA 綁定的是上面的 commit。它含 #264 的外觀修正、#267 的 Performance Probe
（所以同一次安裝可以接著做 [效能量測](performance-probe.md)），以及 #269 修掉的七個
問題。沒有 #269 的版本開不了任何檔案，不要拿來驗收。

2026-11-15 這份表在 iOS 27.0 模擬器（iPhone 17 Pro、iPad Pro 11 吋）上走過 A3、
B1、B5、B7、G 與 H 的入口、K 的設定名稱與量測面板的入口，控制項的名稱與位置已照
畫面校正。模擬器沒有走的：iCloud、中文輸入、背景與終止、衝突、圖片插入、匯出、
無障礙。它們的步驟仍是照原始碼寫的。

## 控制項在哪裡

多數按鈕只有圖示，下面寫的是它們的名稱。

**檔案畫面（標題 Files）**，上排由左到右：Recent Files and Folders（時鐘）、
Recovered Drafts（時鐘加箭頭）、Open File or Folder（資料夾加號）、New File（文件
加號）、Refresh（循環箭頭）、Settings（齒輪）。還沒開任何東西時，畫面中央另有一個
Open File or Folder 按鈕。

**文件畫面**：

- 上排：返回、Settings、Save、Export（分享圖示，內含 Export as HTML、Export as
  PDF、Print）、Find（放大鏡）。iPhone 上 Search in Workspace、Frontmatter、Insert
  Image 收在最右邊的「⋯」裡；iPad 上它們直接排在上排。
- 檔名下方：**Source／Preview** 切換。iPad 的內容區夠寬（900 pt 以上）時改為並排，
  這個切換不會出現。
- 最下方（鍵盤出現時在鍵盤正上方），只在 Source 顯示：Undo、Redo、Bold（B）、
  Italic（I）、Link（鏈條）、Heading 選單（大小 A）、Code 選單（`</>`，內含 Inline
  Code、Code Fence）、Format 選單（Aa，內含 Strikethrough、Paragraph、Quote、Insert
  Inline Math、Insert Display Math、Toggle Checkbox、Format Table）。軟體鍵盤出現時
  最右邊多一個 Hide Keyboard。

**Settings**：Editor 區有 Appearance、Font、Theme、Font size、Line numbers、
Typewriter sync；Saving 區有 Autosave after；Preview 區有 Appearance、Allow remote
images；Files 區有 New file 與圖片資料夾名稱；最下面是 Version。

## 怎麼回報

每一項只需要三種結果之一：**PASS**、**FAIL**、**沒做**。不必填 UTF-16 位移或時間戳。

- 直接回報編號即可，例如「B 全過，D4 失敗，L 沒做」。
- FAIL 請附：編號、實際看到什麼、截圖或螢幕錄影。若牽涉內容遺失，另外說明
  「復原草稿」裡有沒有那份內容。
- 做之前先記下：裝置型號、iOS 版本、簽名方式（見下一節）、注音或拼音。
- 內容遺失、選字被打斷、游標亂跳、多出一步 Undo、未經同意覆寫檔案，一律是 FAIL。
- 只用測試素材和它的拷貝，不要用真正的文章。

## 安裝

沒有付費的 Apple Developer 會員時有兩條路，任選其一，並記下用的是哪一條：

- **重簽這份 IPA**：用自己的免費 Apple ID 和慣用的重簽工具。免費帳號的簽名七天
  到期，bundle ID 可能需要改成自己的（原本是 `app.plainsong.editor.ios`）。只有這條
  路能關閉「重簽安裝」這一項。
- **用 Xcode 從原始碼執行**：在上面那個 commit 的乾淨 checkout 裡 `make generate`，
  對 `PlainsongIOS` target 在本機開啟自動簽名、選個人 team、接上裝置後 Run。這會
  產生另一份 binary，可以用來做 B–M，但 A2 要記為「沒做」。產生的簽名設定不要
  commit。

裝置需要開啟開發者模式。憑證、描述檔、裝置識別碼都不要放進 repo 或回報裡。

## 測試素材

素材包裡的 `fixtures/` 資料夾，整個複製兩份：一份放「檔案」App 的「我的 iPhone」，
一份放 iCloud 雲碟。

| 檔案 | 用途 |
|---|---|
| `kitchen-sink.md` | 所有 Markdown 語法、數學式、Mermaid |
| `kitchen-sink.mdx` | MDX 元件 placeholder |
| `broken-frontmatter.md` | 壞掉的 YAML |
| `perf-100kb.md`、`large-1mb.md` | 大檔的主觀流暢度 |
| `scratch.md` | 可以隨意改的稿子，含勾選框、相對圖片、相對連結與外部連結 |
| `assets/sample.png` | 相對路徑圖片 |

## A. 安裝與啟動

| # | 步驟 | 通過條件 |
|---|---|---|
| A1 | 核對 IPA 的 SHA-256 | 與上表相同 |
| A2 | 重簽並安裝這份 IPA | 安裝成功；記下工具名稱與版本 |
| A3 | 啟動 App | 看到 Files 畫面（No Workspace 與 Open File or Folder 按鈕），不是「Couldn't Start Plainsong」 |
| A4 | 完全關閉後再啟動 | 一樣正常啟動 |

## B. 本機檔案

| # | 步驟 | 通過條件 |
|---|---|---|
| B1 | Open File or Folder → Open Markdown File → 選本機的 `scratch.md` | 直接進入文件畫面，內容正確顯示 |
| B2 | 打幾行字，等自動儲存 | 狀態從未儲存變回已儲存 |
| B3 | 到「檔案」App 預覽同一個檔 | 是原檔被改了，沒有多出一份拷貝 |
| B4 | 回 App，關掉文件再開 | 內容與剛才相同 |
| B5 | Open File or Folder → Open Folder → 進到 `fixtures` 資料夾裡按右上角 Open | 列出裡面的 md／mdx 與 assets；點任一檔可開啟 |
| B6 | 在資料夾內 New File，打字 | 新檔出現在「檔案」App 的同一資料夾 |
| B7 | 完全關閉 App 再開 → Recent Files and Folders → 點項目的名稱（不是 Choose Again） | 剛才的檔案與資料夾都在，點一下就開，不必重新選；那筆紀錄沒有消失 |
| B8 | 在「檔案」App 把 `scratch.md` 改名，再從 Recent 開它 | 明確告知找不到或要求重新選擇；不會默默開別的檔 |

## C. iCloud 雲碟

| # | 步驟 | 通過條件 |
|---|---|---|
| C1 | 對 iCloud 那份重做 B1–B4 | 同 B1–B4 |
| C2 | 對 iCloud 那份重做 B5 | 同 B5 |
| C3 | 在 Mac 上看同一個 iCloud 檔 | 幾分鐘內出現手機上的修改 |
| C4 | 在「檔案」App 對某個檔選「移除下載項目」，再從 App 開它 | 顯示下載中或等待；不會把空白當成內容 |
| C5 | 同 C4，但先開飛航模式 | 明確顯示無法取得；恢復網路後 Refresh 能開 |

## D. 中文輸入與 Undo

注音做一輪，拼音再做一輪。

| # | 步驟 | 通過條件 |
|---|---|---|
| D1 | 在空白行輸入一句中文，中途改選字 | 選到的字正確寫入；選字窗沒有被打斷 |
| D2 | 在標題行（`# ` 之後）、`**粗體**` 中間、行內程式碼中間各輸入中文 | 同 D1；語法上色不會吃掉選字中的字 |
| D3 | 在 emoji（含 👨‍👩‍👧 這類組合）旁邊輸入中文 | emoji 沒有被拆開 |
| D4 | 輸入一句後連按 Undo 到底，再 Redo 到底 | 每一步都是自己做過的動作；回到的內容與原本逐字相同 |
| D5 | 貼上一段文字，Undo 一次 | 整段貼上一次撤銷 |
| D6 | 選字進行中按 Undo | 不會弄壞正在組的字 |
| D7 | 選字進行中切到 Preview 再切回 Source | 文字沒有遺失或重複 |

## E. 背景、終止與復原

| # | 步驟 | 通過條件 |
|---|---|---|
| E1 | 打字後立刻回主畫面，等 10 秒，到「檔案」App 看 | 檔案已有剛才的字 |
| E2 | 打字後立刻鎖定螢幕，30 秒後解鎖 | 內容還在，且已儲存 |
| E3 | 打字後立刻回主畫面，從多工畫面把 App 滑掉，重開 | 檔案有那些字，或 Recovered Drafts 裡有 |
| E4 | 在 Recovered Drafts 選一筆 → Restore as New File | 產生新檔，內容與草稿相同；原檔沒被動 |
| E5 | 對不要的草稿 Remove Record | 只刪那一筆 |

## F. 外部修改與衝突

| # | 步驟 | 通過條件 |
|---|---|---|
| F1 | App 開著一個已儲存的 iCloud 檔，在 Mac 上改它 | App 自動更新成 Mac 的內容 |
| F2 | App 裡先打字（還沒存），同時在 Mac 上改同一個檔 | 出現「File changed outside this editor」；自己打的字還在 |
| F3 | 在 F2 的狀態選 Save a Copy | 產生新檔，內容是手機上的版本；原檔保持 Mac 的版本 |
| F4 | 重做 F2，改選 Reload | 換成 Mac 的內容；手機的版本可以在 Recovered Drafts 找到 |
| F5 | 手機開飛航模式改檔，同時 Mac 也改；手機恢復網路 | 出現 Review iCloud Versions，可以看兩個版本的內容 |
| F6 | 在 F5 選一個版本 → Use Selected Version | 檔案變成選的那個版本；另一個沒有無聲消失 |
| F7 | 在「檔案」App 刪掉 App 正在開的檔 | App 明確告知；手上的內容沒有丟 |

## G. 編寫工具

| # | 步驟 | 通過條件 |
|---|---|---|
| G1 | 選一段字，下方工具列的 Bold、Italic、Code 選單的 Inline Code、Heading 選單的 Heading 2 各試一次 | 加上對應語法；Bold、Italic、Inline Code 再按一次可取消；各是一步 Undo |
| G2 | 下方工具列的 Link，填 label 與 URL | 插入 `[label](url)` |
| G3 | 開 `kitchen-sink.md` 的 Frontmatter，改 title 與 tags | 原始碼的 frontmatter 跟著改；其他欄位不變 |
| G4 | 對沒有 frontmatter 的檔 Add Frontmatter | 檔案開頭加上 `---` 區塊 |
| G5 | 開 `broken-frontmatter.md` 的 Frontmatter | 顯示錯誤與原文；原始碼一個字都沒被改 |
| G6 | Find（放大鏡）開啟 Find and Replace，搜尋中文詞，Find Next／Find Previous | 計數正確，會捲到並選取該處 |
| G7 | Replace 一次 | 只換目前那一處；一步 Undo 可還原 |
| G8 | Replace All | 全部換掉；一步 Undo 全部還原 |
| G9 | Insert Image → Photos，選一張照片 | 圖檔存進文件旁的資料夾，插入 `![](…)`，預覽看得到 |
| G10 | Insert Image → Files，選一張圖 | 同 G9 |
| G11 | 開始插入圖片後按 Cancel | 文件沒有變，沒有留下孤兒圖檔 |
| G12 | 只開單一檔案（不是資料夾）時插入圖片 | 要求先選資料夾，不會自己寫到別處 |

## H. 預覽

| # | 步驟 | 通過條件 |
|---|---|---|
| H1 | 開飛航模式，開 `kitchen-sink.md` 看 Preview | 表格、程式碼上色、數學式、Mermaid 圖都正常 |
| H2 | 在 Source 打字後切到 Preview | 是最新內容；鍵盤自動收起；字的大小正常，不是縮小的整頁 |
| H3 | 開 `kitchen-sink.mdx` 看 Preview | 元件顯示為卡片，import 顯示為一行標籤；沒有空白頁 |
| H4 | 在 mdx 裡打一個沒關的 `<Tag`，看 Preview | 顯示錯誤橫幅，下面保留上一次的畫面 |
| H5 | 文件裡放一張 `https://` 圖片，設定保持預設 | 不載入；在 Settings › Preview 開 Allow remote images 後才載入 |
| H6 | 資料夾模式下看 `scratch.md` 的 Preview | `assets/sample.png` 顯示 |
| H7 | 點預覽裡的勾選框 | 原始碼對應那行的 `[ ]`／`[x]` 跟著變 |
| H8 | 點預覽裡的外部連結 | 用 Safari 開，只開一次 |
| H9 | 點預覽裡指向另一個 `.md` 的相對連結 | 在 App 裡開那個檔 |

## I. 資料夾搜尋

| # | 步驟 | 通過條件 |
|---|---|---|
| I1 | 資料夾模式 → Search in Workspace，搜一個中文詞 | 列出各檔的符合處；點了會開檔並跳到那一行 |
| I2 | 改了某個檔後再搜一次 | 結果反映新內容 |

## J. 匯出與列印

| # | 步驟 | 通過條件 |
|---|---|---|
| J1 | 對 `kitchen-sink.md` Export as HTML，存到「檔案」 | 用 Safari 開，離線下樣式、數學式、圖片都在 |
| J2 | Export as PDF | PDF 可開，內容完整，是淺色版面 |
| J3 | Print | 出現系統列印畫面，預覽正確（不必真的印） |
| J4 | 匯出進行到一半取消，再匯出一次 | 第二次正常完成 |

## K. 外觀與設定

K1–K2 是 #264 修的問題，請特別看。

| # | 步驟 | 通過條件 |
|---|---|---|
| K1 | 系統設深色；Settings › Editor › Appearance 選 Light | 編輯器底色、文字、行號欄全部是淺色，沒有深色殘留 |
| K2 | 系統設淺色；Editor 的 Appearance 選 Dark | 全部是深色 |
| K3 | Editor 的 Appearance 選 System，切換系統外觀 | 跟著系統變 |
| K4 | 文件最後一行按 Enter 留一個空行 | 那個空行有行號 |
| K5 | 很長、會折行的段落 | 只有第一個顯示行有行號 |
| K6 | 改 Font size、Line numbers、Theme | 立刻生效；重開 App 後還在 |
| K7 | 開 Typewriter sync，在長文件中間打字後切到 Preview | 預覽停在打字的那一段附近 |

## L. iPad

需要一台實體 iPad。借到之前整節記「沒做」，其餘各節不受影響。

| # | 步驟 | 通過條件 |
|---|---|---|
| L1 | 在 iPad 上重做 A2–A3、B1–B5、D1、D4 | 同各項 |
| L2 | 橫向全螢幕。若看到的是 Source／Preview 切換而不是並排，把左邊的檔案側欄收起來（並排需要內容區 900 pt 以上） | 原始碼與預覽並排，兩邊是同一份文件 |
| L3 | 旋轉、Split View、Slide Over 之間切換 | 文字、游標、Undo 都保留；窄的時候改為切換式 |
| L4 | 接實體鍵盤：打字、⌘Z、⌘⇧Z、⌘B、⌘I、⌘F | 都作用在目前的編輯器；⌘Z 一次只還原一步 |
| L5 | 實體鍵盤下用注音選字 | 同 D1 |

## M. 無障礙（有時間再做）

| # | 步驟 | 通過條件 |
|---|---|---|
| M1 | 開 VoiceOver，從啟動畫面開一個檔 | 每個按鈕都唸得出用途 |
| M2 | VoiceOver 下在編輯器、預覽、工具列之間移動 | 焦點順序合理，三處都到得了 |
| M3 | 系統字級調到最大 | 介面沒有被截斷到無法操作 |

## 主觀流暢度

不是正式量測，只記印象：在 `perf-100kb.md` 與 `large-1mb.md` 的開頭、中間、結尾
各打一段字，記下有沒有明顯的延遲或掉字，以及發生在哪個檔的哪個位置。

## 做完之後

結果記在 `docs/ios/evidence/device-pass-<日期>/`，並更新
`docs/ios/integration-ledger.md` 與 `docs/release-1.0-scope.md` §3。FAIL 的項目各開
一個修正 PR；修完重出 IPA，只重測失敗與受影響的項目。
