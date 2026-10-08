# Lane 12 — toolchain preflight（本機實測）

日期：2026-10-08。探測機器：owner Mac（darwin 27.0.0）。所有值為本次實測，
不是文件假設；preflight script 以相同檢查在每次 run 重新驗證。

## 實測 inventory

| 項目 | 實測值 | 對 spec 的結論 |
|---|---|---|
| `xcode-select -p` | `/Applications/Xcode-beta.app/Contents/Developer` | beta toolchain 為 active |
| `xcodebuild -version` | Xcode 27.0, build `27A5194q` | iOS SDK 由 Xcode 決定 → 27.0 |
| `xcodebuild -showsdks` | `iphoneos27.0`, `iphonesimulator27.0`（另有 DriverKit 27.0） | **無 iOS 26 SDK**；SDK 27 可編譯 deployment target iOS 26.0（契約要求 `.iOS("26.0")`，是 deployment target 不是 SDK 版本）→ preflight 檢查設計為「SDK >= 26」而非「== 26」 |
| `xcrun simctl list runtimes` | **零 iOS runtime** | `ios-test`／`ios-build`（simulator destination）目前會早期失敗；安裝 runtime 是 owner 動作：`xcodebuild -downloadPlatform iOS` |
| `xcrun simctl list devices` | **零 device** | device types 已知（iPhone 17 Pro 等）但無 runtime → 無可建 simulator destination |
| `xcrun devicectl list devices` | 1 台 iPhone 14 Pro（`unavailable`，未連線） | unsigned IPA 不需實機；owner 重簽安裝關卡仍是 OPEN |
| `xcodegen --version` | 2.45.4 | `xcodegen generate` 實測成功：4 Mac targets + 7 schemes 生成正常 |
| `xcodebuild -project … -list` | Targets: Plainsong / PlainsongTests / PerformanceTests / PlainsongUITests；Schemes: EditorKit、MarkdownCore、PerformanceTests、Plainsong、PreviewKit、SwiftTreeSitter、WorkspaceKit | baseline inventory 留證；iOS target 出現與否是 lane-12 manifest 驗證點 |
| `swiftformat --version` | 0.61.1 | CI pin 0.62.1（Makefile `SWIFTFORMAT_VERSION`）；本機低版只產生既有 warning，lane-12 不升级 |
| `swiftlint` | 0.65.0 | 現有 lint 鏈沿用 |
| `swift --version` | Swift 6.4 toolchain（target arm64-apple-macosx27.0.0） | contracts 要求沿用現有 language mode，不做 Swift 6 migration |
| `node`/`npm` | v24.16.0 / 11.18.0 | iOS pipeline 依賴已提交的 `App/Resources/preview` bundle；不重建 |
| 簽名／檢查工具 | `codesign` `security` `plutil` `otool` `vtool` `ditto` `zip` `unzip` `xcrun` `actool` 全部存在 | nested signing-state 檢查可實作 |
| 共享鎖 | `/private/tmp/plainsong-xcodebuild-test.lock` 存在（0 bytes，空閒） | iOS runner 固定此路徑；`PLAINSONG_XCODEBUILD_LOCK` 設成別的值 → 明示拒絕（exit 2） |
| `make generate` | 在本 worktree 實測成功（xcodeproj 為 gitignored，不留追蹤檔） | generate→build 流程可行 |

## Preflight 設計（`ios-preflight.sh` draft）

檢查順序與失敗碼：

1. 工具存在（`command -v`）：`xcodebuild xcodegen xcrun git plutil codesign vtool lipo ditto zip shasum /usr/bin/python3` → 缺任一 exit 2。
2. `PLAINSONG_XCODEBUILD_LOCK`：unset 或等於 canonical `/private/tmp/plainsong-xcodebuild-test.lock`；其他值 exit 2（不各自用不同鎖）。
3. `xcodebuild -showsdks` 解析 `iphoneos`、`iphonesimulator` 版本 → 各自 < 26 exit 2。
4. `--need-simulator`（build/test 入口）：runtime 列表需有 iOS ≥ 26 且有 available iPhone；缺 → exit 2 並印 `xcodebuild -downloadPlatform iOS` 提示（腳本不自動下載）。
5. `--write-evidence <dir>`：寫 `preflight.json`（版本、SDK、runtime 數、source SHA/dirty、canonical lock）——metadata 的 toolchain 區塊。

## 已辨識環境缺口（owner／環境前置，非 lane-12 可自解）

- **iOS simulator runtime 未安裝** → `ios-build`／`ios-test` 在 runtime 到位前會以明確訊息失敗；`ios-archive` 只需 `iphoneos` SDK，不依賴 simulator。
- **Xcode 是 beta（27A5194q）** → IPA 產線若要求 release toolchain，metadata 記錄實際 build version；是否接受 beta toolchain 由 owner/13 決定，lane-12 不自行假設。
- **iOS 26 SDK 字面不存在**（只有 27.0）→ 依契約語意 `>= 26` 檢查；若 13 判定必須是 Xcode 26 toolchain，屬環境安裝事項。
