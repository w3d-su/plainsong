# Lane 10 → 13：C0 最小 wiring request

依 handoff：「C0 的 scaffolding 不完整時向 13 提供最小 wiring request；不能自己新增
第二個 AppState 或模擬保存成功。」以下每項若不進 C0，lane-10 只能發明平行 API
（被禁止）或停工。

## 1. Target／scaffold

| # | 需求 | 理由 |
|---|---|---|
| W1 | `AppIOS` app target skeleton＋單 scene entry（13-owned `AppIOS/App/**`）＋`AppIOSTests` hosted test target（scheme 註冊） | lane-10 寫不了 `project.yml`／Makefile；沒有 target 就沒有可編譯落點與測試入口（contracts.md §8、handoff 08 同樣指出 test target 由 C0 提供） |
| W2 | `AppIOSTests/Shell/**` 預留目錄被 target 自動納入 | 避免每線各改 manifest |

## 2. Consumer-facing 凍結名稱

contracts.md 凍結了 provider protocol 的 *語意*，但下列 **shell 這一側要調用／掛載的
具體名稱** 尚未在任何檔案出現；請 C0 以 Swift declaration 一次定義，否則 04–09／10／13
會各自長出不同名稱：

| # | 名稱（建議，13 定奪） | 消費方式 |
|---|---|---|
| W3 | `IOSSceneServices`（或等義）：scene state facade——`open(location)`、`newFile()`、`saveAs()`、`resolveExternal(choice:)`、document `IOSDocumentState`/`IOSDocumentEvent` 觀察、workspace snapshot publisher、recents | shell 所有「開啟／新建／另存／狀態」動作的單一入口；13 的 composition 接真實 05／06；fake 只在 tests |
| W4 | 04 的 SwiftUI editor hosted view 型別名（例 `IOSSourceEditorView`）＋mount 參數（attach 用 identity、callback seam） | container 掛載 editor |
| W5 | 07 的 iOS preview hosted view 型別名（例 `IOSMarkdownPreviewView`） | container 掛載 preview |
| W6 | `IOSAuthoringAction` descriptor 的 consumer seam：shell 如何 *列舉* descriptors（id、title、icon、shortcut、enablement 依據）＋取得 handler（接收 editor facade 的閉包型別） | toolbar／keyboard 安裝（contracts.md §7 已定 08 擁 descriptors、10 安裝；缺列舉型別） |
| W7 | 08 frontmatter／find／replace hosted view 與 09 image-picker flow 的 vend 型別（例 `IOSAuthoringViews`／`IOSImageInsertionFlow`）：SwiftUI `View` 工廠或 `UIViewController` provider，二選一凍結 | `.sheet` 呈現 |
| W8 | Scene 與 editor facade 的綁定宣告：「04 的哪個物件實作 `IOSSourceEditorControlling`、由誰（13 composition？04 attach callback？）在 document attach 時交給 scene」 | router 的 `editorFacade` 來源；這是 contracts.md §2 adapter callback「13 在 C0 定義 consumer 需要的 callback 名稱」的具體一格 |

## 3. 語意確認（不改契約，請 13 在 C0 註記）

| # | 問題 | lane-10 預設假設 |
|---|---|---|
| W9 | 隱藏的 preview 是否繼續接收 render？ | 預設：繼續（切回即最新；morphdom patch 便宜）。若 11 perf 要求暫停，由 container 加 pause 控制，不影響 identity 不變條件 |
| W10 | Editor↔preview scroll sync 在 iOS 首版？ | 預設：不在（handoff UX 只要求 scroll *保留*）。若要，屬額外 proposal |
| W11 | Document switch 時 sheet 一律 dismiss？ | 預設：是（pending proposal 綁舊 identity） |
| W12 | Compact 模式預設 segment | source |

## 4. 不需要 C0 的（lane-10 自給）

`IOSShellSceneState`、`IOSShellActionRouter`、`IOSContentLayout` policy、
`IOSShellPresentation`、status chrome、doubles——全部是 lane-10 內部 view／view-model，
不進 frozen surface。

## 5. 依賴時序

- W1–W8 是 lane-10 *實作* 的前置；W9–W12 是 review 前確認即可。
- 04–09 真實 providers 不是 lane-10 module PR 的前置（doubles 驗收）；是 13
  composition PR 的前置。
