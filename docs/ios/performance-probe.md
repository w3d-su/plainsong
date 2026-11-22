# iOS 效能量測（I3）

日期：2026-11-15。工具：App 內建的 Performance Probe
（`AppIOS/Features/PerformanceProbe`）。設計與限制見
[決策紀錄](../decisions/2026-11-15-ios-performance-probe.md)。

每一項在實機上量過並記錄之前都是 **OPEN**。模擬器的數字只能當診斷。

## 它量什麼

| 指標 | 意義 | agent.md §12 預算 |
|---|---|---|
| Insert | 插入呼叫返回 | — |
| Commit | 主執行緒完成該次編輯的版面、繪製與送出 | 16 ms |
| Refresh | commit 之後第一次螢幕更新 | — |
| Highlight | 該次按鍵的可視範圍上色完成 | 50 ms |
| Preview render | 交給 JavaScript 到 `renderComplete`，不含 150 ms 防抖 | 100 ms（100 KB 文件） |

**Commit 不等於「按鍵到畫面」。** 字實際亮在面板上的時間通常比 Refresh 再晚一次螢幕
更新，App 內部量不到。所以 Commit 的 p95 低於 16 ms 表示 App 沒有拖慢那一格，不能
單獨關閉「按鍵到畫面 16 ms」這個關卡。

沒有量的：注音／拼音的組字過程（工具打的是字母 `x`）、開檔時間。

## 量之前

- 用 Release 建置（驗收包裡的 IPA 就是）。Debug 建置的報告會被標成不可採用。
- 關閉低耗電模式，拔掉充電線後等機器不燙，關掉其他 App。
- 這台 Mac 上若正在跑 Xcode 建置或模擬器，而裝置是接著線的，先等它們結束。
- 只用測試素材的**拷貝**。工具會在文件裡打字再刪掉，檔案會被自動儲存。

## 步驟

每台裝置做一輪，共六次量測：

1. 開啟 `perf-100kb.md`，點一下編輯區讓鍵盤出現。iPad 請用並排版面，讓預覽也在畫面上。
2. Settings → 捲到最下面 → 連點 **Version** 那一列五下 → 出現 **Performance Probe** → 點它。
3. Caret 選 **Start**，按 **Start**。過程約 30–40 秒，期間不要碰螢幕。
4. 結束後按 **Share Report**，把 JSON 存到「檔案」或 AirDrop 到 Mac。
5. 按 **Run Again**，Caret 依序改成 **Middle**、**End** 各做一次。
6. 換開 `large-1mb.md`，重做 3–5。

面板上若出現黃色警告（低耗電、過熱、樣本不足、文件沒有還原），那一次不算，排除原因後
重做。「文件沒有還原」請另外回報，並把那個檔案丟掉換一份新的拷貝。

## 回報與記錄

把六個 JSON 檔交回來即可，不必自己整理。每個檔已含裝置型號、系統版本、熱狀態、畫面
更新率、文件雜湊與全部原始樣本。

結果記為 `docs/perf/<日期>-ios-device-<裝置>.md`（格式見 `docs/perf-log.md` 開頭），
原始 JSON 放 `docs/ios/evidence/device-pass-<日期>/`，再更新
`docs/release-1.0-scope.md` §3 的 Performance 列。

## 怎麼讀結果

- 預算比的是 p95。`budgets` 陣列列出每個有樣本的指標是否在預算內。
- `highlightMissing` 是等待時間內沒有上色完成的按鍵數。不為零表示上色慢於等待上限
  （預設 500 ms）或被後續按鍵取代，要看原始樣本。
- `previewWasVisible` 為 false 時，預覽不在畫面上，WebKit 可能降速，Preview render 的
  數字只能參考。iPhone 的原始碼模式就是這種情況。
- `frameIntervalMilliseconds` 約 16.7 表示這次以 60 Hz 取樣。iPhone 即使是 120 Hz 面板
  也是如此，因為 App 沒有在 Info.plist 要求更高更新率。
- `large-1mb.md` 驗的是內容正確與能否順暢編輯，不套用 100 KB 的預覽預算。
