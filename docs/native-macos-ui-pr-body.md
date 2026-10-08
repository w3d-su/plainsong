## Summary

Native Files selection, grouped Settings, shared NoticeBar surfaces and Apple preview colors accompany the new macOS window chrome. macOS **27+** uses NavigationSplitView with the resizable/collapsible 220–320 pt sidebar (⌃⌘S). macOS **14–26** retains the fixed-width HStack sidebar. The navigator icons, jump bar, compact layout toolbar and trailing Frontmatter/File inspector keep existing Search/Find identifiers.

At narrow Split widths, the inspector previously squeezed the editor away. The editor and Preview now each keep **260 pt**; Split requires **521 pt**. A constant **900 pt** window minimum covers the widest sidebar and chrome allowance. Geometry auto-collapses the inspector while SceneStorage preserves user intent; widening restores it only when requested. Explicit Show widens the window by the deficit within the screen visible frame, or leaves it automatically collapsed if there is insufficient room.

## Scope and integration

- Inspector menus reflect visible state, disable without a document, and clear synchronously on resign/close.
- Native Files keyboard selection opens files while retaining navigator focus. Default activation still requests editor focus. The narrow activation parameter in AppState+Workspace.swift is permitted by handoff 29; the live #151 diff does not touch that file.
- Rows retain native selection and plain-text node-ID dragging; image providers additionally expose URLs consumed by the existing editor drop decoder.
- Dark function/link/comment colors exceed 4.5:1 on #2a2a2c. Generated preview assets are committed; embedded HTML/PDF export CSS changes with them.
- Dirty jump bars announce Edited; single-file segments use static text; the inspector handle exposes 10 pt adjustable accessibility actions.
- No Find/Replace, command dispatcher, MenuBarState or export-banner files are changed. Workspace Search retains its owned NSTextField and F6/F7 routing.
- Integration order is **{L, B1} → B2 → C**; L lands first. B1 must preserve the navigator focus parameter. Window-state C inherits scene chrome intent/width.

## R17 and scheduling evidence

The split column keeps fixed geometry derived from its proxy and constants. Historical macOS 15 split-view constraint crashes are why the native split shell is restricted to verified macOS 27+.

The final review build completed **30/30** separately signed launches on macOS 27: 20 workspace fixtures and 10 normal last-file-bookmark restorations, with no constraint exception or new Plainsong crash report. The owner app was not launched or terminated.

The inspector uses plain sections and a key-window registry rather than SwiftUI .inspector or focused values. The historical scheduling root cause remains unknown (**R22**). Window-state C must retain all attempts from two sensitive Find tests run 16 times each with the inspector mounted. Green reruns do not close that causal question.

## Validation

- [x] Both production shell width/intent matrices on macOS 27: **36 measured samples each, 72 total**, including Source/Split/WYSIWYG, widest sidebar, pane floors, no overlap, automatic restore, explicit Hide and Show.
- [x] Final focused checks: **8 passed, 1 inactive-mouse skip, 0 failed**. Foreground dev-app single-click selection was observed separately. Arrow focus and image-provider/real-editor-decoder checks passed.
- [x] Full hosted app/performance suite excluding PlainsongUITests: **830 passed, 10 skipped, 0 failed**. Includes Find/Replace, F6/F7 and ExportHTML/ExportPDF gates (44 passed, 3 HTML skips).
- [x] Four package suites: **1,201 total, 7 skips, 0 failures**.
- [x] Preview: **127 passed**, typecheck and regenerated preview bundle.
- [x] Build, pinned SwiftFormat 0.62.1 lint and whitespace checks. Lint retains 329 warnings, 0 serious.
- [x] Final-build R17 launch loop; light/dark Preview and minimum/restore/explicit-hide screenshots.
- [ ] macOS 15 exact-head CI after orchestrator review/push. Local forced HStack coverage ran on macOS 27.
- [ ] Owner macOS 27 F9 10,000-match/WS4A UI command, FKA/IME/VoiceOver, physical image drag and full dark-system chrome screenshot.

Full hosted results contain 217 runtime warnings (SceneStorage/Environment outside a hosted scene, publishing during view update and QoS inversion); no warning-free or idle performance acceptance is claimed. Earlier failed harness attempts and final corrections remain recorded.

See docs/native-macos-ui-review-evidence.md for exact test names, artifacts, screenshots and the prepared owner UI-test command. This file is a local replacement-body draft for the orchestrator; remote metadata is unchanged until reviewed local commits are pushed.
