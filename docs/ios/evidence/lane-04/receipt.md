# Lane 04 receipt — EditorKitIOS

Status: **module-ready**. Not product-integration-ready. M0 device gates are open.

| Field | Value |
|---|---|
| Branch | `phase3-ios-editor-kit-ios` |
| Base | `refs/tags/ios-c0-v1` / `642cb212703220409874a2741c5adbfb8c80fe8a` |
| Contract | IOS-C0-v1. `Contracts.swift` was not edited |
| Package manifest | Unchanged from C0. Dependencies remain MarkdownCore and SyntaxKit |
| Head | The commit that adds this file on `phase3-ios-editor-kit-ios` |
| PR base | `phase3-ios-integration` |

## What landed

`IOSSourceEditorController` is the native `UITextView` + TextKit 2 writer. It implements `IOSSourceEditorBinding`: snapshot, synchronous `apply`, `reveal`, undo/redo, attach/detach, access and command focus, external reload, and main-actor observation.

Authoring and image mutations enter only through `IOSAuthorizedEdit`. A refusal returns before any native replacement, so source, selection, and undo are unchanged. One accepted format or single Replace is one native undo group. The action name is set after `replace(_:withText:)`, because that call otherwise labels the group "Replace".

Native typing publishes once through `DocumentSession.replaceTextFromAuthorizedEditor`. Statistics are counted off the main actor and dropped when the revision moved. Highlighting uses one debounced runner, at most one executing parse, and at most one newer request behind it. Results apply only when identity, revision, presentation generation, theme, viewport, and the exact UTF-16 fragment still match. Attribute edits do not register undo.

## Doubles

| Seam | This delivery |
|---|---|
| 02 `MarkdownSyntaxTokenizing` | Injected. Tests use a continuation gate. Production init defaults to `nil` and does not invent tokens |
| 05 / 13 document host | Tests attach a real `DocumentSession` through `IOSSourceEditorDocumentBinding`. There is no second editable string |
| App shortcut wiring | Not done. 10 installs 08 descriptors. This lane does not edit the app target |

## Simulator verification

Command, from `Packages/EditorKitIOS`, under `/private/tmp/plainsong-xcodebuild-test.lock`:

```sh
xcodebuild test -scheme EditorKitIOS \
  -destination 'platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66' \
  -derivedDataPath /tmp/plainsong-ios-editor-kit-dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Destination: iPhone 17 Pro, iOS 27.0 simulator. Result: **TEST SUCCEEDED**, 16 tests, 0 failures.

Passed tests:

- `EditorContractConsumerTests.testConsumerCanObserveUnavailableEditorWithoutCreatingSource`
- `IOSSourceEditorInputTests.testTextKit2SurfaceAcceptsTraditionalChineseEmojiAndPasteOnceEach`
- `IOSSourceEditorInputTests.testEnterTabPairFenceAndTableUseMarkdownEditingOnce`
- `IOSAuthorizedEditTests.testFormatAndSingleReplaceAreOneNativeUndo`
- `IOSAuthorizedEditTests.testImageInsertionIsOneUndoAndRefusalsLeaveSourceSelectionAndUndoUntouched`
- `IOSAuthorizedEditTests.testSelectionABAAccessReadOnlyMarkedTextFocusRangeAndBusyRefuse`
- `IOSHighlightPresentationTests.testRepeatedHighlightKeepsSourceSelectionAndUndo`
- `IOSHighlightPresentationTests.testStaleThemeAndViewportResultsAreDiscarded`
- `IOSHighlightSchedulerTests.testBlockedParseThenEditsRunsOnlyTheLatestRequest`
- `IOSHighlightSchedulerTests.testHideReappearAndUnmountDropLateResults`
- `IOSHighlightSchedulerTests.testReconciliationFloorRejectsAnAlreadyProducedResult`
- `IOSMarkedTextGuardTests.testFormatImageAndHighlightDoNotDisturbMarkedText`
- `IOSReconciliationTests.testSameSourceKeepsPresentationAndDifferentMiddleReparsesWithoutTyping`
- `IOSReconciliationTests.testComposingReloadIsDeferredAndHideKeepsUndo`
- `IOSReconciliationTests.testSwiftUIUpdateDoesNotResetTheNativeBuffer`
- `IOSHighlightPerformanceDiagnosticTests.testFixtureScansRunOffMain`

SwiftFormat 0.62.1 was run on `Packages/EditorKitIOS`. SwiftLint reports no error in that package. Mac `make test` was not run; C0 owns that regression on the integration commit.

## Diagnostic scan, not a budget

`testFixtureScansRunOffMain` reads `Fixtures/perf-100kb.md` (91486 UTF-8 bytes) and `Fixtures/large-1mb.md` (1048962 UTF-8 bytes). The fake tokenizer scanned off the main thread. One simulator sample: 100 KB about 11 ms, 1 MB about 108 ms. Scheduling the task returned in under 0.01 ms. These numbers are not the device p95 typing or visible-highlight gates.

## UIKit API check

Context7 library `/websites/developer_apple_uikit` confirmed `textLayoutManager` (iOS 16+), `replace(_:withText:)`, `markedTextRange`, and `NSTextViewportLayoutController.viewportRange`. The same lookup described `init(usingTextLayoutManager:)`. The iOS 27 SDK header does not provide that initializer. It provides `+textViewUsingTextLayoutManager:` and says `init(frame:textContainer:)` with a nil container uses TextKit 2. This editor calls that designated initializer and never reads `layoutManager`, because doing so falls back to TextKit 1. `setMarkedText(_:selectedRange:)` is the UITextInput method in `UITextInput.h`; the three Context7 calls did not return that snippet.

## Still open

- Real Zhuyin / Pinyin candidate confirmation, selection, and native Undo on device. See [device-acceptance.md](device-acceptance.md).
- Real SyntaxKit parser from lane 02.
- Lane 05 / 13 production attach of the same `DocumentSession`.
- Hosted `PlainsongIOS` test target wiring stays with lanes 12 and 13. This package scheme is the module test.
- Device p95 keystroke under 16 ms and visible highlight under 50 ms.
