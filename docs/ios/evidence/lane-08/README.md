# Lane 08 — 格式、Frontmatter、Find／單次 Replace：交付摘要

日期：2026-10-08。契約版本：IOS-C0-v1。推理等級：L3。

## 狀態宣告

實作基線是 tag `ios-c0-v1`（`642cb212703220409874a2741c5adbfb8c80fe8a`），以 merge commit 進入 `phase3-ios-authoring-tools`。沒有把後來的 integration docs commit 當基準，也沒有 force-push。

這是 **module tests on a private fake**。M0 真機 gate 未通過。本文件不宣布 module-ready，也不宣布 product-ready。04 的 hosted editor、10 的快捷鍵安裝、中文 composing、VoiceOver、硬體鍵盤與真實 Undo 都還沒跑。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-authoring-tools` |
| 實作基準 | `ios-c0-v1` = `642cb212703220409874a2741c5adbfb8c80fe8a` |
| PR | https://github.com/w3d-su/plainsong/pull/155。寫入本檔時 GitHub base 仍是 `phase3-ios-parallel-handoffs`。推送實作 commit 之後把 base 改成 `phase3-ios-integration`，不 merge |
| 修改路徑 | `AppIOS/Features/Authoring/**`、`AppIOSTests/Authoring/**`、`docs/ios/evidence/lane-08/**` |
| Doubles | `AuthoringEditorFake` 與 `RecordingFindScheduler` 只在 `AppIOSTests/Authoring/`。沒有第二份 public editor protocol |
| 快捷鍵 | `IOSAuthoringCatalog` 只提供 descriptor。`installsKeyCommands == false`。View 沒有 `UIKeyCommand` 或 SwiftUI `.keyboardShortcut` |

## 已執行的檢查

Simulator：iPhone 17，`platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4`（iOS 27.0）。Derived data：`/tmp/plainsong-ios-authoring-dd`。Signing 關閉。共用 lock：`/private/tmp/plainsong-xcodebuild-test.lock`。

```sh
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4' \
  -derivedDataPath /tmp/plainsong-ios-authoring-dd \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PlainsongIOSTests/IOSAuthoringGuardedEditTests \
  -only-testing:PlainsongIOSTests/IOSFormattingActionTests \
  -only-testing:PlainsongIOSTests/IOSFrontmatterPanelTests \
  -only-testing:PlainsongIOSTests/IOSFindGenerationTests \
  -only-testing:PlainsongIOSTests/IOSSingleReplaceTests \
  -only-testing:PlainsongIOSTests/AuthoringContractConsumerTests \
  test
```

2026-10-08 20:43，`** TEST SUCCEEDED **`。76 tests，0 failures：

| Class | 結果 |
|---|---|
| `IOSAuthoringGuardedEditTests` | 9 passed |
| `IOSFormattingActionTests` | 18 passed |
| `IOSFrontmatterPanelTests` | 16 passed |
| `IOSFindGenerationTests` | 17 passed |
| `IOSSingleReplaceTests` | 13 passed |
| `AuthoringContractConsumerTests` | 3 passed |

Fake 斷言記錄 `apply`／`reveal`／refusal／text／selection／兩個 generation／undo 次數，不是只比對 label。SwiftFormat 0.62.1 `--lint` 對這 16 個 Swift 檔回報 0 files require formatting。SwiftLint 對這些檔案沒有 error；`replaceCurrentMatch` 有 function-body warning（54／50），`editCommand` 有 complexity warning（13／10）。提交前 `git diff --cached --check` 通過。

Code、Inline Code、Code Fence 只放在 toolbar 的 Code 群組。Handoff 第 41 行要把 Inline Code 與 Code Fence 放在 Format menu；凍結的 `IOSAuthoringActionPlacement` 每個動作只能有一個位置，存在性測試要求 Code 群組。說明見 `source-investigation.md` 的「實作落點」。

MarkdownCore 沒有改動。`IOSDocumentContractTests` 屬於 MarkdownCore test target，不是 PlainsongIOS scheme 的成員。2026-10-08 20:44 對該 scheme 使用 `-only-testing:MarkdownCore/MarkdownCoreTests/IOSDocumentContractTests` 與 `test-without-building`，xcodebuild 在執行任何測試前失敗（exit 70）：`MarkdownCore isn't a member of the specified test plan or scheme`。因此不把 `IOSDocumentContractTests` 記成通過或失敗。

`PersistenceAssetContractConsumerTests` 在 PlainsongIOSTests，但不在上面 76 項裡。補跑見下一節。

## 同一 scheme 的補跑

同一台 iPhone 17 simulator、同一 derived data，對已建好的 PlainsongIOSTests 使用 `test-without-building`，只跑 `PlainsongIOSTests/PersistenceAssetContractConsumerTests`。2026-10-08 20:48，`** TEST EXECUTE SUCCEEDED **`，3 tests，0 failures，exit 0。這不是重新編譯，也不是 `IOSDocumentContractTests`。

## 未跑

- `Scripts/ios/c0.sh test` 的完整 scheme（SyntaxKit、WorkspaceCore、WorkspaceKitIOS、EditorKitIOS 全套）未跑。本 lane 沒有改那些 package。
- 04 hosted editor 的 source／selection／Undo before-after：未跑。
- 10 把 descriptor 裝上 scene 之後的硬體鍵盤：未跑。
- Owner-only 真機：注音／拼音 marked text、VoiceOver、硬體鍵盤只觸發一次、真實 Undo。未跑。不勾 M0。

## 文件索引

- [`source-investigation.md`](source-investigation.md) — MarkdownCore 呼叫點與 adapter 規則。實作依此，不另寫 planner。
- [`named-test-design.md`](named-test-design.md) — 方法名單。對應的 XCTest 已在上面的 simulator run 通過。
- [`c0-dependency-request.md`](c0-dependency-request.md) — 請求已由 `ios-c0-v1` 滿足。沒有追加 public API。

## 關卡分列

- **本 lane module fake：** 五個 named class 與 catalog／guarded route 已在 iOS 27 simulator 通過。
- **待整合：** 04 真實 editor；10 安裝快捷鍵；05 的 read-only／conflict 先推進 access generation。
- **Owner-only 真機：** 中文 composing、VoiceOver、硬體鍵盤、真實 Undo。M0 未過。

## 不做的事

- 不改 editor、`DocumentSession`、Mac Find／Frontmatter、任何 package、`project.yml`、Makefile、CI、`agent.md`、Decision Log、integration ledger、其他 lane。
- 不提供 workspace search、regex、Replace All、WYSIWYG replace。
- 不 merge 自己的 PR，不 force-push，不改 owner checkout `/Users/davis._.su/Documents/blogeditor`。
