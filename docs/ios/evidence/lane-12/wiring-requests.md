# Lane 12 → 13：C0 交接時需要凍結／確認的項目

依 handoff：全域 manifest／build 檔由 13 在 bootstrap 建最小 scaffold，C0 freeze
時明確交接給 12。以下缺一項，lane-12 只能發明平行命名（被禁止）或停工。

## 1. 交接本身

| # | 需求 | 理由 |
|---|---|---|
| W1 | 明確的 13→12 **handoff commit**（`project.yml`／`Makefile`／`Scripts/ios/`／`.github/workflows/ios.yml`／build 文件所有權轉移），並公布 `IOS_BASE_REF`＋精確 `IOS_BASE_SHA` | README 台帳欄位「Global build ownership handed to 12」；沒有交接 commit 前 lane-12 不寫全域檔案 |
| W2 | C0 在 `project.yml` 留下的 scaffold 形狀：`PlainsongIOS`／`AppIOSTests`（名稱若不同請凍結實名）、`AppIOS/**` sources、preview folder resource 掛法 | handoff：「12 只引用 C0 的正式 target／product 名稱，不自建另一組 package stub」；lane-12 據此擴充 test targets／resources |
| W3 | `Scripts/ios/` 在交接時是空目錄還是 13 留 scaffold；若 13 留檔，列出檔名 | 避免同名檔案衝突（lane-12 draft 已備齊，見 `drafts/Scripts/ios/`） |

## 2. Target／產品命名

| # | 需求 | lane-12 預設假設（draft 用） |
|---|---|---|
| W4 | iOS bundle identifier（必須 ≠ Mac `app.plainsong.editor`） | `app.plainsong.editor.ios` |
| W5 | iOS packages 的 XcodeGen `packages:` 名稱與 product 名（`SyntaxKit`／`WorkspaceCore`／`EditorKitIOS`／`WorkspaceKitIOS`——後者 manifest 13 獨占）＋`PlainsongIOS` 依賴哪幾個 | 依 contracts.md §1 層次全列；未到位 provider 的依賴由 13 scaffold 決定加不加 |
| W6 | 11 的 required-resources manifest 交付路徑與格式（bundle-relative 一行一路徑？） | lane-12 暫以 `Scripts/ios/required-app-resources.txt`＋`required-test-resources.txt` 承接，11 交付後併入；測試資源保留相對 bundle 路徑 |
| W7 | `IOSAcceptanceTests` target 的 type（`bundle.unit-test` vs `bundle.ui-testing`）與 scheme 掛法 | draft 暫用 unit-test＋`PlainsongIOS` scheme testTargets；11 用 XCUITest 的話改 ui-testing＋獨立 scheme |

## 3. Info.plist／entitlements／.gitignore

| # | 需求 | lane-12 預設假設 |
|---|---|---|
| W8 | iOS `AppIOS/Info.plist` 的文件型別寫法確認（`LSSupportsOpeningDocumentsInPlace`/`UISupportsDocumentBrowser`/`.md`/`.markdown` 沿用 `net.daringfireball.markdown` imported UTI、`.mdx` 用 `app.plainsong.mdx` exported UTI——iOS 需要 Mac 同組 UTI declarations 嗎？） | draft 同 Mac 語意複製 UTI 宣告，不複製 sandbox entitlements |
| W9 | iOS entitlements：C0 是否留白（無檔案）；iCloud／document-browser capability 何時加 | 預設無 entitlements 檔；禁止把 Mac sandbox/hardened-runtime/bookmark 整份複製 |
| W10 | `.gitignore` 需新增 `AppIOS/Info.plist`、`AppIOS/*.entitlements`（generated）——handoff 指定由 13 更新 | 列入 request，lane-12 不改 .gitignore |

## 4. 行為確認（不改契約）

| # | 問題 | lane-12 預設 |
|---|---|---|
| W11 | 「需 iOS 26 SDK」按字面（Xcode 26）還是 SDK≥26？本機 Xcode 27β 只有 `iphoneos27.0` | 按 SDK≥26（deployment target 26.0）；若必須 Xcode 26 toolchain 屬環境安裝事項，請明示 |
| W12 | `SyntaxKit`／`WorkspaceCore` 若宣告 macOS 平台，是否進 Mac `swift test` loop？ | lane-12 傾向由 13／module owner 決定；PACKAGES 保持現值，iOS-only 套件永不進 |
| W13 | ios.yml runner image 標籤（需含 iOS≥26 SDK+runtime 的 image）與 Xcode select 方式 | draft `macos-26`＋TODO；13 若已驗證某 image 請凍結標籤 |
| W14 | `make ios-*` 是否寫進 `agent.md` §15 命令表（13 擁有） | 請 13 在交接 commit 同步加一行 |

## 5. 不需要 C0 的（lane-12 自給）

`ios-common.sh`/`ios-preflight.sh`/四個 runner/resource-preflight/metadata schema/
staging 規則/ios.yml 骨架——全部 lane-12 檔案，不進 frozen surface，等交接後落地。
