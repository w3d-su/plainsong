# 07 — PreviewKit 跨平台與協調資源讀取

## 任務與智力需求

- **建議：L4 最高階推理。** 共享 WebKit lifecycle、render stale-drop、checkbox round-trip 與非同步資源讀取的 root／token race 都涉及安全與內容正確性；須讓 Mac 既有 preview／export tests 持續通過。
- Branch：`phase3-ios-preview-ios`。依 [總表](../README.md) 在 isolated worktree 開發。
- 目標：PreviewKit 同時支援 macOS／iOS，新增 UIKit representable／平台適配與可注入 coordinated resource reader，共用既有 committed preview bundle、MDX placeholder、KaTeX／Mermaid／fence rendering。
- 首版不提供 HTML／PDF export UI、MDX execution、WYSIWYG。既有 Mac export API／policy／protocol 必須保持相容。

## 起跑條件與並行關係

1. 13 integrator 完成 C0：凍結 resource reader／access context／preview binding 契約、scaffold 和現有 bridge baseline 後起跑。
2. 依賴 C0 MarkdownCore 的 iOS support；可和 04 editor、05 document、06 browser、App shell 並行，以 C0 mock reader 測 root races。01 專責 M0 真機驗證。
3. 真實 provider resource reader 由 06 實作，本 lane 不 dependency-import WorkspaceKitIOS；integration 注入，避免下層 cyclic dependency。
4. Real provider wiring 與完整 app acceptance 必須等 06 真實 provider＋M0 owner gates；SwiftUI／WebKit 模擬器成功不代表 iCloud asset access 通過。

## Exclusive write paths

- `Packages/PreviewKit/Package.swift`
- `Packages/PreviewKit/Sources/PreviewKit/**`，但 C0 指定的 frozen contract file 及 `BridgeMessage.swift`／`ExportBridgeMessages.swift` 例外，保持只讀。
- `Packages/PreviewKit/Tests/PreviewKitTests/**`
- 本 handoff 的 evidence section。

禁止修改 `preview-src/**`、`App/Resources/preview/**`、App／AppIOS、WorkspaceKitIOS、其他 packages、global project／Makefile／CI／架構文件。不是以 `make preview-bundle` 修 native platform 問題。若確需改 wire protocol，停下交 C0 owner 同時分配 Swift＋TS＋bundle＋PROTOCOL_VERSION，不能單方面修改其中一邊。

## 現有程式與平台改動

- `PreviewController.swift` 現在 import AppKit，使用 `NSColor`／`wantsLayer`／`NSWorkspace.open`；改成條件式小型 platform adapter。保留同一 main-actor controller、message proxy、WKWebView 和 render lifecycle。
- `MarkdownPreviewWebView.swift` 保留 Mac NSViewRepresentable／host；新增 iOS UIViewRepresentable／host。Layout mode 變更只重新 attach 同一 web view，不每次建立／reload page。
- 讓 package 支援既有 macOS 14＋計畫 iOS 26。避免把 Mac export runtime 全部移除來換取 iOS compile；Mac-only API 用可辨識 conditional boundary，shared lifecycle／bridge decoding 仍測。
- `PreviewController` 的 `renderID` 跨 documents 單調遞增，不能改用 session-local version。Checkbox 必須仍比對 latest render ID、source version、originating DocumentSession instance；error DOM 也不得發送假冒最新 revision 的 edits。
- Single-file mode 現在可由 file parent 推導 allowedRoot。iOS 新 authority context 必須實際具 directory grant 才可允許 sibling assets；只有 file grant 時設為無資源權限並回報要求資料夾存取，不能拿 parent URL 當授權。

## Resource reader 與安全契約

- Reader 型別為 C0 的 `PreviewAssetReading`：單一 async request／validated response，request 帶 grant ID／access generation。Mac default adapter 保持現有 direct-read compatibility，iOS 必須由 06 的 leased／coordinated provider 供 bytes／metadata／authority generation。PreviewKit 擁有 policy，reader 不能選擇放寬它。
- 讀取前後都驗證 current root identity、access generation、opaque asset-root token、request lifetime。相同 URL 重新取得 grant 也要 invalidate 舊 authority；取消／stop／controller invalidate 後不再發 callback。
- **現有 race：** `AssetURLSchemeHandler` 起始 captured root，completion 目前只檢查 stoppedTaskIDs。新增 reader 后，要在 read 完成及 `didReceive`／`didFinish` 前再次比對 root context；不能把 root switch 前的 bytes 交給新 web context。
- 保留 component-safe containment、符號連結 escaping 拒絕、PNG／JPEG／GIF／WebP allowlist、10 MiB 上限，以及讀前 metadata／讀後 byte-count checks。Provider relocated accessor URL 必須在 coordinated read 內重新驗證；read helper 不得 cache 未授權 URL。
- 沿用 asset query token（`plainsong-root`）與既有 bridge fields，不修改 JS protocol。新 context generation 以 native root-token regeneration 保護；舊 token 請求必須失敗。
- 沿用 sanitizer／strict CSP、remote image 預設關閉，只在既有顯式 preference 下允許 HTTPS image；外部連結交 iOS platform opener／App event，仍攔 navigation，relative markdown links交 app validated open route。
- Bridge 首次 ready version 檢查、Web content process termination／recovery、queued-latest-render、theme、scroll owner 與 error DOM 保留必須在兩平台一致。

## 測試與驗收

- 用 existing kitchen-sink／MDX／malformed fixtures 驗證 Markdown、table、code、math、Mermaid、component placeholders、MDX error retains last good DOM；完全離線可 render。
- Controlled reader：阻住 root A 讀取→switch B→release A；same URL／new grant generation；stop→late read；invalidate→late result；不得送舊 bytes 或 callback。Negative probe 拿掉 completion root fence，必須可靠失敗。
- Asset adversarial cases：percent-encoded traversal、prefix sibling、symlink escape／讀取中替換、missing／bad token、wrong extension、unsupported SVG、size grows after metadata／over limit、single-file sibling read 拒絕；policy 不因 provider read 成功而跳過。
- Race cases：A v9→B v0 仍靠 renderID drop；error DOM checkbox、latest／origin session mismatch、rapid observe switches、rotate／editor-preview toggle、WebKit process termination。source／selection／undo 必須未變。
- iOS hosted WKWebView tests 與現有 Mac PreviewKit／export bridge／resource／lifecycle tests；有 conditional exclusions 時具體列 tests 與理由，不以 Mac green 假稱 iOS 執行過。
- 真機 owner：folder granted image、未下載 iCloud 圖、regrant／root switch、remote-off、Safari external link、iPad rotation／layout toggle。100 KB render <100 ms 與另計 150 ms debounce 由 11 validation／真機 lane 驗收。

## Stop gates 與 PR evidence

- 若需 protocol／bundle 變更、platform port 改變 Mac export security、或無法在 provider accessor 內驗證 containment：停在 failing test／design evidence，交 integrator 重配範圍。不能禁用 security checks 讓 iOS 測試 green。
- PR 附 base／head SHA、contract version、Mac＋iOS build／named tests、race＋negative-probe 證據、bundle／protocol unchanged diff、expected excluded tests、manual／performance gates，以及給 integrator 的 global docs 變更。
- 必須獨立 L4 review／Claude review，不自行 merge／force-push；歷史 CI 不能替代本 PR exact-head verification。

## Evidence（由執行者填寫）

尚未執行；此 handoff 沒有跨平台 PreviewKit、iCloud 圖片或效能驗收結果。

## 可直接貼給其他 LLM 的任務

```text
請執行 Plainsong iOS lane 07：PreviewKit iOS，建議 L4 最高階推理。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/07-preview-ios.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-preview-ios。只改 PreviewKit 允許路徑與自己的 tests。
保留 Mac 行為，加入 UIKit host/platform adapter、PreviewAssetReading 接點與 late-read fences。
不改 frozen contracts、bridge protocol、preview-src 或 committed JS bundle。
根目錄/token/grant generation、raster type/size/symlink/CSP checks 必須仍有效。
先用 mocks；06 providers 和 01 M0 gates 通過後才能產品接線。
驗證 stale reads、render/checkbox identity、Mac export regression與 iOS hosted tests，
留下 SHA、negative probes、manual/performance open gates 供 Claude/L4 review。
不自行 merge、force-push 或修改 owner checkout；共享需求交 13 integrator。
```
