# Lane 12 — 測試與 failure-gate 計畫

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

「已跑」與「設計」分列；pre-C0 無 iOS target 可建，所有 build/test/archive/IPA
實跑都是 post-handoff 項目。

## A. 已執行（本 worktree，2026-10-08）

| 檢查 | 命令 | 結果 |
|---|---|---|
| draft shell 語法 | `bash -n drafts/Scripts/ios/*.sh` | 6/6 PASS（ios-common／ios-preflight／run-ios-build／run-ios-tests／run-ios-archive／run-ios-ipa） |
| draft python 語法 | `python3 -m py_compile ios-resource-preflight.py` | PASS |
| manifest 生成 | `xcodegen generate` + `xcodebuild -list` | PASS：Mac 4 targets／7 schemes 生成正常（baseline inventory 留存） |
| toolchain inventory | `xcodebuild -version/-showsdks`、`simctl list` | 已記錄於 toolchain-preflight.md；**iOS runtime=0 → ios-build/ios-test 目前必失敗（正確的早期失敗）** |
| ios.yml YAML lint | 未跑（系統 python3 無 PyYAML） | **未跑即未跑**；交接後以 actionlint 或 review 補 |

## B. 負向測試（交接後必跑，全部要求明確 nonzero + 訊息）

| # | 情境 | 預期 |
|---|---|---|
| N1 | `bash -n` 對每個 Scripts/ios 腳本 | 任一語法錯 → CI/本地立刻 exit≠0 |
| N2 | `PLAINSONG_XCODEBUILD_LOCK=/other/path make ios-build` | exit 2，訊息指明 canonical 路徑 |
| N3 | `IOS_DESTINATION='platform=iOS Simulator,id=DEADBEEF'` | exit 2，列出 `-showdestinations` 實際可用 iOS destination |
| N4 | 無 iOS runtime 時 `make ios-test` | exit 2，訊息含 `xcodebuild -downloadPlatform iOS`（本機現況即此情境，可現驗） |
| N5 | `make ios-ipa` 而 output root 只有前一 head 的 archive | 非零退出；**不得重包舊 archive**；metadata 記錄 stale archive |
| N6 | resource manifest 列了不存在的路徑 | resource-preflight exit 3，報告 missing list |
| N7 | archive 內 app 為 simulator Mach-O（platform IOSSIMULATOR） | run-ios-archive exit 4 |
| N8 | nested framework 簽名移除失敗 | run-ios-ipa exit 2，signing.txt 保留 before/after |
| N9 | Payload staging 混入 DerivedData／mobileprovision／p12 | zip 前拒絕，非零 |
| N10 | 鎖被佔時第二個 run | 只印「still pending」並等待／timeout exit 75；不 kill |
| N11 | `make build`／`make test`／`make release` | 與 baseline 完全相同行為（不產 IPA、不選裝置） |
| N12 | Mac `swift test` loop | `EditorKitIOS`/`WorkspaceKitIOS` 不出現在 PACKAGES；iOS-only 套件不在 Mac host 跑 |

## C. 正向驗收（post-handoff + providers）

- `make ios-build`：`PlainsongIOS.app`（Debug-iphonesimulator）產出，build.log＋build.json。
- `make ios-test`：xcresult＋named-tests.txt 列出實際執行的 named tests；退出碼=xcodebuild。
- `make ios-archive`：Release `.xcarchive`，`vtool` platform=IOS、arm64、resources 全在、nested signing 全記錄。
- `make ios-ipa`：`.ipa` unzip 後只有 `Payload/PlainsongIOS.app`；全部 code bundle unsigned；`.sha256` 可重算吻合。
- iOS CI（manual dispatch）：同 head 的 artifact＋toolchain.txt 齊全；失敗 attempt 保留。

## D. 關卡分列（交付時照此格式回報 13）

- **local**：本 worktree 實跑結果（目前僅 A 區）。
- **exact-head hosted**：ios.yml workflow_dispatch 結果（runner image／Xcode 記錄）。
- **owner-only**：重簽 IPA 安裝啟動＋Files 讀寫——lane-12 只交付 **BUILD PASS / INSTALL OPEN**，不關此關。
