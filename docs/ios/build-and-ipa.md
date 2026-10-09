# iOS 建置、測試與未簽名 IPA 指南

Lane 12 交付（`docs/ios/handoffs/12-build-and-ipa.md`）。本檔描述固定入口的用法、
產物格式與 owner 重簽流程。Scope：`project.yml`／`Makefile`／`Scripts/ios/**`／
`.github/workflows/ios.yml` 由 lane-12 獨占（C0 交接 receipt：`docs/ios/c0-baseline.md`）。

## 前置需求

- Xcode 含 **iOS SDK ≥ 26**（`xcodebuild -showsdks` 會在每次 run 重新驗證；
  SDK 27 可編譯 deployment target iOS 26.0）。
- `make ios-test` 需要已安裝的 **iOS ≥ 26 simulator runtime 與實際 device UUID**；
  沒有 runtime 時 `xcodebuild -downloadPlatform iOS` 由 owner 執行（腳本不自動下載）。
  `ios-build` 不帶 `IOS_DESTINATION` 時使用 `generic/platform=iOS Simulator`，
  無 runtime 也能產生編譯證據；`ios-archive` 只需 device SDK。
- `xcodegen`、`/usr/bin/python3`、`codesign`、`vtool`、`lipo`、`ditto`、`zip`、`shasum`。
- 共享鎖固定為 `/private/tmp/plainsong-xcodebuild-test.lock`；
  `PLAINSONG_XCODEBUILD_LOCK` 設成其他路徑會被明示拒絕（exit 64）。外層已持鎖時
  不要呼叫這些 runner（內層不會再取鎖）。未取得鎖只回報排程等待（exit 75）。

## 固定命令

```sh
make ios-build   [IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>']
make ios-test    IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
make ios-archive [IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release]
make ios-ipa     [IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release]
```

`ios-test` 的 `IOS_DESTINATION` 必填且必須是已安裝 runtime 的實際 UUID；
`Scripts/ios/ios-print-simulator-udid.sh` 可印出第一個可用的 iOS ≥ 26 iPhone UUID，
錯誤/不存在的 UUID 會以 exit 64 失敗並列出可用選項。

| 入口 | 行為 | 主要產物 |
|---|---|---|
| `ios-build` | preflight → `xcodegen generate` → `PlainsongIOS` Debug simulator build，`CODE_SIGNING_ALLOWED=NO`，per-head/run 隔離 DerivedData | `dd/<head>-build-*/`、`evidence/<head>-build-*/`（build.log、build.json、macho-platform.txt、archs.txt、signing-state.txt） |
| `ios-test` | → build-for-testing → resource preflight（manifest＋preview 逐檔 SHA-256 parity）→ `test-without-building -parallel-testing-enabled NO` | `evidence/<head>-test-*/`（build-for-testing.log、resources.json、Results.xcresult、named-tests.txt、test.json）；exit code 保留 xcodebuild 結果 |
| `ios-archive` | → `archive -destination 'generic/platform=iOS' -configuration Release`，signing 全關 | `PlainsongIOS-<head12>.xcarchive`＋`*.xcarchive-meta/`（head stamp、archive.json、signing.txt、resources.json） |
| `ios-ipa` | 找 head-matched archive（無→同鎖內先跑 archive；**只有異 head 的 archive → 拒絕重包**）→ `Payload/` staging → 由內而外 strip 全部簽名並驗證 → zip | `PlainsongIOS-<head12>.ipa`＋`.ipa.sha256`＋`.xcarchive.sha256`（archive 內容 manifest digest）＋`ipa-meta-<head12>/ipa.json`＋`signing.txt` |

## Unsigned 語意與檢查

- archive 用 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`；不使用需要簽名的
  `-exportArchive` 冒充 unsigned export。
- `ios-ipa` 逐一檢查 app 內每個 `.framework`/`.appex`/`.xctest` 與 app 本身的
  `codesign -dv` 狀態（記錄 before）；非 unsigned 則 `codesign --remove-signature`
  並再驗證，殘留即交付失敗（exit 4）。`_CodeSignature` 殘餘與
  `embedded.mobileprovision`／`*.p12` 移除並記錄；zip 前再掃，任一殘留 → 拒絕。
- `Payload/` 只允許 `PlainsongIOS.app`；混入任何其他檔案 → 拒絕 zip。
- Mach-O 驗證：`vtool -show-build` 必須 `platform IOS`（`IOSSIMULATOR` 會失敗）、
  `lipo -info` 必須含 arm64。

## Metadata

每個 runner 的 `*.json` 記錄：source SHA＋dirty、contract version（`IOS-C0-v1`）、
`ios_base_sha`（tag 解出的 SHA）、命令與 destination、Xcode/SDK 版本
（preflight.json）、configuration、resource manifest 每項 sha256（resources.json）、
archive/IPA 路徑＋SHA-256＋bytes、每個 code bundle 的 before/after signing state、
起訖時間、exit code。**不含環境 dump 與 credential。** 宣告的是可重現流程，
不是逐位元一致 IPA。

## CI（`.github/workflows/ios.yml`）

`workflow_dispatch` only——不加 `push`/`pull_request`（private macOS 費用控制）。
`concurrency: ios-<ref>`；artifact 名帶 `run_id`/`run_attempt`，失敗也上傳。
runner image 須含 iOS ≥ 26 SDK 與 runtime；`toolchain.txt` 記錄實際
image／Xcode／SDK。`ios-test` 在無 runtime 時以明確訊息失敗，不假裝通過。

## Owner 重簽與安裝（INSTALL OPEN）

lane-12 交付的是 **unsigned** IPA；安裝到真機需要 owner 用自己的簽名重新簽署。
一般流程（owner 操作，lane-12 不代做、不保存任何憑證）：

1. 解開 IPA：`unzip PlainsongIOS-<sha>.ipa` → `Payload/PlainsongIOS.app`。
2. 用自己的 provisioning profile＋`codesign -fs "Apple Development: <name>"`
   （或 Apple Configurator 2 / Sideloadly 類工具）對 **每個 nested bundle 由內而外、
   最後 app 本體** 重簽，放回匹配的 `embedded.mobileprovision`。
3. 重新打包 `Payload/` 為 `.ipa`，用 `xcrun devicectl`、Apple Configurator 或
   Xcode Devices 視窗安裝到已註冊裝置。
4. 驗證啟動與 Files 文件讀寫（含 iCloud Drive）。

這些步驟的實際觀察（免費帳號 7 天簽名期限、工具鏈相容性、真機 Files 存取）
在 owner 完成前都是 **OPEN**。unsigned IPA 產出本身只代表 **BUILD PASS**。

## 退出碼慣例

| code | 意義 |
|---|---|
| 0 | 成功 |
| 2/64 | 用法／設定錯誤（壞 destination、非 canonical lock path、缺 manifest） |
| 3 | 產物結構錯（缺 .app、無 head-matched archive） |
| 4 | 平台／簽名違規（非 device Mach-O、簽名殘留、Payload 污染） |
| 5 | resource preflight 失敗 |
| 65 | 資料錯誤（manifest 缺檔、head 不符的既有 archive） |
| 69 | 工具鏈／SDK／runtime 不存在 |
| 75 | 共享鎖排程逾時（仍 pending，未執行） |
| 其他 | xcodebuild 原始退出碼原樣保留 |
