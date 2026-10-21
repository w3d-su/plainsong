# Lane 12 — 建置／測試／archive／IPA 入口設計

狀態：**設計完成，未落地**。`project.yml`／`Makefile`／`Scripts/ios/**`／`.github/workflows/ios.yml`
目前屬 13 bootstrap 所有權；C0 freeze 且 13 明確交接 commit 後，本設計經 review 平移到全域檔案。
Draft 全文在 [`drafts/`](drafts/)（已通過 `bash -n`／`py_compile`，見 test-plan.md）。

## 1. Makefile（additive only）

```sh
make ios-build   IOS_DESTINATION='platform=iOS Simulator,id=<uuid>'   # Debug sim build
make ios-test    IOS_DESTINATION='platform=iOS Simulator,id=<uuid>'   # build-for-testing → resource preflight → test-without-building
make ios-archive IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release   # generic arm64 Release .xcarchive
make ios-ipa     IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release   # unsigned .ipa + .sha256 + metadata
```

- `PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit` **不改**——`EditorKitIOS`／`WorkspaceKitIOS`
  永不進 Mac `swift test` loop（UIKit 不能在 Mac host 跑）。共用套件回歸：
  `SyntaxKit`／`WorkspaceCore` 若 manifest 宣告 macOS 平台，由 13／module owner 決定是否進 `PACKAGES`；
  lane-12 只保證 iOS-only 套件不進去（draft snippet 用註解固定此規則）。
- `SWIFT_FORMAT_PATHS` 追加 `$(wildcard AppIOS AppIOSTests IOSAcceptanceTests)`：
  wildcard 在目錄不存在時展開為空，C0 前 lint 不破壞，C0 後自動涵蓋。SwiftFormat pin 不動。
- `build`／`test`／`release` 行為完全不變；iOS 入口只透過 `ios-*` 觸達。

## 2. Scripts/ios/ 版面

| 檔案 | 角色 |
|---|---|
| `ios-common.sh` | sourced helper：canonical lock 強制、`lockf -k` 外層 wrapper（e9 同型）、工具檢查、SDK ≥26 檢查、simulator UUID 解析/驗證、per-head/run output dir、nested signing 檢查＋移除、metadata JSON writer |
| `ios-preflight.sh` | 獨立可呼叫的 toolchain gate；`--need-simulator` 供 build/test；`--write-evidence` 產 preflight.json |
| `run-ios-build.sh` | lock → preflight → generate → Debug sim build（`CODE_SIGNING_ALLOWED=NO`）→ app/Mach-O/arch/signing 記錄 |
| `run-ios-tests.sh` | lock → preflight → generate → build-for-testing → **resource preflight**（manifest 逐項 sha256）→ test-without-building `-parallel-testing-enabled NO` → named-tests.txt → 保留 xcodebuild 退出碼 |
| `run-ios-archive.sh` | lock → preflight → generate → `archive -destination 'generic/platform=iOS'`（`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`）→ 驗證 device Mach-O/arm64/resources → nested signing 全記錄 → `<archive>-meta/head` stamp |
| `run-ios-ipa.sh` | lock → 找 head-matched archive（無→同鎖內跑 archive；有但非本 head→拒絕）→ `ditto` → staging `Payload/` → nested→app 順序 strip 簽名並驗證 → 拒絕 mobileprovision/p12 殘留 → zip → sha256 → ipa.json metadata |
| `ios-resource-preflight.py` | manifest（一行一個 bundle-relative path）對多 root 驗存在＋sha256；missing → exit 3；寫 resources.json |
| `required-app-resources.txt` / `required-test-resources.txt` | lane-12 擁有的資源清單；11 的 acceptance resources 交付後併入（wiring-request W6） |

## 3. 固定鎖語意

- 每個 `run-ios-*.sh` 頂端 `ios_lock_or_exec "$0" "$@"`：無鎖 → `lockf -k -t 0` 非阻塞探測＋300 s 期限每 30 s 重試（同 e9）；已鎖（`--locked`）直接執行。內層 helper（ipa→archive re-entry、resource preflight）不再取鎖。
- `PLAINSONG_XCODEBUILD_LOCK` 只接受 unset 或 canonical 值；異值 exit 2。等待鎖只印「still pending」，exit 75，不 kill 他人。
- generate／xcodebuild／simctl 全程在同 process tree 的鎖內。

## 4. Destination 與平台驗證

- `IOS_DESTINATION` 設了 → `xcodebuild -showdestinations -scheme PlainsongIOS` 驗證 `id:` 存在；
  沒設 → `simctl list -j devices available` 挑 newest iOS≥26 runtime 的第一支 available iPhone；
  兩者都不行 → exit 2 並列出可用 destination。不猜名字。
- archive 驗證：`vtool -show-build` 需含 `platform IOS`（IOSSIMULATOR → fail）、`lipo -info` 需含 arm64、
  `Products/Applications/PlainsongIOS.app` 存在、manifest resources 全在。
- `ios-ipa` 的 archive head 匹配：`<archive>-meta/head` == `git rev-parse HEAD`，否則拒絕重包。

## 5. Unsigned 語意（L3 review 點）

- 產線 flag：`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`；不走 `-exportArchive`（其有簽名需求，會冒充不了 unsigned export）。
- strip 順序：nested `.framework`/`.appex`/`.xctest` 由內到外，app 最後；`codesign --remove-signature` + 刪 `_CodeSignature` + 驗證 `codesign -dv` 變 not-signed；任一殘留 → 交付失敗（exit 2），不只看 app 外層。
- `embedded.mobileprovision`／`*.p12`／keychain：staging 內發現即記錄並移除；zip 前 `find` 再查，殘留 → 拒絕。
- Payload 只准含 `PlainsongIOS.app`；`Payload/` 出現其他 top-level 檔 → 拒絕 zip。

## 6. Metadata（`ipa.json`／`archive.json`／`build.json`／`test.json`）

欄位（handoff §「metadata」逐項對應）：source SHA + dirty、contract version（`IOS-C0-v1`）、
command+參數、Xcode/SDK 版本、destination/architecture、configuration、manifest 每項 sha256
（resources.json）、archive/IPA path+sha256+bytes、每個 code bundle 的 before/after signing state
（signing.txt）、start/end timestamp、exit code。**不 dump 環境變數、不含 credentials。**
宣告「可重現流程」，不宣稱逐位元一致 IPA。

## 7. `.github/workflows/ios.yml`

- `on: workflow_dispatch` only——無 push／pull_request（private macOS 10x 費用控制，同 ci.yml 註解脈絡）。
- `concurrency: ios-${{ github.ref }}`，artifact 名帶 run_id+run_attempt，失敗也上傳，rerun 不覆蓋。
- runner image 需含 iOS ≥26 SDK + runtime；實作時驗證 image label（draft 暫標 `macos-26` + TODO），
  image／Xcode 版本寫入 toolchain.txt 證據。
- 步驟：checkout → toolchain 記錄 → xcodegen → IOS_OUTPUT_ROOT 指 runner-temp → `ios-build` →
  `ios-test` → `ios-archive` → `ios-ipa` → `always()` 上傳 evidence＋IPA＋sha256＋metadata。
- 不上傳 DerivedData／環境 dump；IPA artifact 只屬本次暫存 evidence。

## 8. project.yml 增量（draft 在 `drafts/project-yml.snippet.yml`）

`PlainsongIOS`（iOS app，deploymentTarget 26.0，bundle id `app.plainsong.editor.ios` 與 Mac 分離，
sources=`AppIOS`+共用 `App/Resources/preview` folder ref）＋`AppIOSTests`＋`IOSAcceptanceTests`（11 的
tests 接入 scheme）。正式 target／product 名稱以 C0 為準（wiring-request W1/W2），lane-12 不自創。

## 9. 驗證順序（交接後執行）

1. `make generate` → `xcodebuild -list` 核對 target/scheme inventory（Mac 4 targets 原值＋新 iOS）。
2. `bash -n` 全部 scripts；負向測試（test-plan.md）。
3. `make ios-build` → `make ios-test`（需 simulator runtime）。
4. `make ios-archive` → `make ios-ipa` → unpack IPA 驗 `Payload/PlainsongIOS.app`、Mach-O platform、
   resources、nested signing-state。
5. Mac 回歸：`make build`／`make test`／`make lint`／`git diff --check`（固定鎖下序列化）。
