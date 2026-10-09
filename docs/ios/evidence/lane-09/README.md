# Lane 09 — 圖片插入交易：交付摘要

日期：2026-10-08。契約版本：IOS-C0-v1。推理等級：L4。

## 狀態宣告

實作基準是 tag `ios-c0-v1`（`642cb212703220409874a2741c5adbfb8c80fe8a`）。沒有把 integration docs commit 當基準，也沒有 force-push。

這是 **module tests on private fakes**。`PausableImageWriter` 與 `ImageEditorFake` 只實作凍結的 `IOSWorkspaceAssetWriting` 與 `IOSSourceEditorControlling`。04 的 native writer、06 的 coordinated filesystem、以及 M0 真機 Files／iCloud／Photos 都還沒接上。本文件不把 module pass 說成 product integration-ready。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-image-insertion` |
| 實作基準 | `ios-c0-v1` = `642cb212703220409874a2741c5adbfb8c80fe8a` |
| 修改路徑 | `AppIOS/Features/Images/**`、`AppIOSTests/Images/**`、`docs/ios/evidence/lane-09/**` |
| Frozen contracts | 未改。消費 `IOSWorkspaceAssetWriting`、`IOSStagedImageAsset`、`IOSAuthorizedEdit`、`IOSSourceEditorControlling`、`SmartPaste.imageInsertion`、`MarkdownImageAssetPolicy` |
| Doubles | writer／editor fake 只在 `AppIOSTests/Images/`。沒有第二份 public writer 或 editor protocol |
| Photos／Files API | Context7：`/websites/developer_apple_photosui` 的 `PHPicker`（`selectionLimit = 1`、`preferredAssetRepresentationMode = .current`、delegate 須自行 dismiss）；`/websites/developer_apple_uikit` 的 `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`。HEIC 以 ImageIO 編成新的 PNG bytes，不改副檔名 |

Head SHA 與 PR URL 以 GitHub 上這個 branch 的 tip 為準；本 lane 不 merge。

## 交易

捕捉 snapshot 與 directory grant → off-main 正規化 → `stage` 持久化 → `validate` → 同一個 binding／document／revision／selectionGeneration／accessGeneration、可寫、聚焦、非 composing，才同步 `apply`。accepted 才 `commit`。其他終點 `rollback` 一次；cleanup indeterminate 留 relative path，不依 URL 刪檔。Undo／Redo 只動文字。時間線與反例在 [`transaction.md`](transaction.md)。方法名單在 [`named-tests.md`](named-tests.md)。

## 已執行的檢查

Simulator：iPhone 17，`platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4`。Derived data：`/tmp/plainsong-ios-image-insertion-dd`。Signing 關閉。共用 lock：`/private/tmp/plainsong-xcodebuild-test.lock`。

```sh
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4' \
  -derivedDataPath /tmp/plainsong-ios-image-insertion-dd \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PlainsongIOSTests/IOSImageInsertionOrderingTests \
  -only-testing:PlainsongIOSTests/IOSImageInsertionStaleTests \
  -only-testing:PlainsongIOSTests/IOSImageInsertionTerminalTests \
  -only-testing:PlainsongIOSTests/IOSImageInsertionPolicyTests \
  -only-testing:PlainsongIOSTests/IOSImageInsertionPathTests \
  test
```

2026-10-08 23:57 CST，`** TEST SUCCEEDED **`。49 tests，0 failures：

| Class | 結果 |
|---|---|
| `IOSImageInsertionOrderingTests` | 5 passed |
| `IOSImageInsertionPathTests` | 5 passed |
| `IOSImageInsertionPolicyTests` | 7 passed |
| `IOSImageInsertionStaleTests` | 17 passed |
| `IOSImageInsertionTerminalTests` | 15 passed |

SwiftFormat 0.62.1 與 SwiftLint 對上述 Swift 檔在提交前再跑一次；結果寫在 commit 時的工作樹，不把 Mac package 的既有 warning 算進本 lane。

## 未跑

- 06 的真實 file coordinator、ownership、namespace replacement。fake 只依凍結 protocol 的 generation／workspace id。
- 04 hosted editor 的 native Undo stack 與實際 IME。fake 的 Undo 只還原文字，並斷言沒有呼叫 writer rollback。
- 真機 Photos picker、Files／iCloud、尚未下載、離線 provider、背景寫入、composing 期間打開 picker。
- 07 preview 用同一個 authorized root 顯示插入後的圖片。
- 完整 `PlainsongIOS` scheme 裡其他 package 的測試。本 lane 沒有改那些 package。

## 關卡分列

- **本 lane module fake：** 五個 named class，49 tests，iOS Simulator 通過。
- **待整合：** 13 把真實 06 writer 與 04 editor 注入 `IOSImageInsertionController`。10 負責把 view 放進 shell。
- **Owner-only 真機：** Files／iCloud 授權、未下載資產、Photos、composing 期間開 picker、自行簽名後的資源存取。未跑。不勾 M0。
