# iOS: fixes from the first walk of the production app through its real UI

Date: 2026-11-15

## Decision

Seven defects found by driving `PlainsongIOS` through the system document picker and its
own controls in iOS 27.0 simulators are fixed together, before the owner's device pass
(`docs/ios/device-pass.md`). Each blocked a section of that pass.

| Defect | Cause | Fix |
|---|---|---|
| Open Markdown File / Open Folder did nothing, with no message | SwiftUI clears a `.sheet(item:)` binding when the picker dismisses, before UIKit's delegate reports the pick. `completePicker` compared against the cleared `pickerRequest` and dropped the URL | The issuance is tracked apart from the presentation. Ending the presentation hides the sheet; the delegate's one terminal result still consumes the issuance. A newer request, a cancel or a retirement replaces it. Same change in the recovery "Restore as New File" and conflict "Save a Copy" folder pickers, which had the same shape, and in the Insert Image → Files picker, whose sheet is built the same way (its race was not reproduced) |
| One tap on a Recent row ran Open, Choose Again and Remove Record | A `List` row runs every default-style button in it on a row tap | `.buttonStyle(.borderless)` on the row |
| No way to reach the preview on iPhone | The Source/Preview control was the navigation bar's `.principal` item; with two leading and four trailing items the bar dropped it | The control is a row under the document header |
| No Undo/Redo, Bold, Italic, Link, Heading, Code or Format control on iPhone, and their shortcuts were never installed | `ToolbarItemGroup(placement: .keyboard)` attaches only to SwiftUI's own text inputs; the editor is a UIKit text view | `IOSAuthoringKeyboardBar`, an ordinary view at the bottom of the document column while the source pane shows. The keyboard pushes it up. It also has Hide Keyboard while the software keyboard is up |
| Preview text was about 40% size on iPhone | `index.html` had no viewport meta, so WebKit laid the page out 980 px wide and scaled it | `<meta name="viewport" content="width=device-width, initial-scale=1">` (also sets the layout viewport of `IOSDocumentExport`'s off-screen 800 pt web view for iOS PDF/Print export instead of WebKit's 980 px default) |
| An iPad's navigation bar showed "Heading 1", "Heading 2", … drawn on top of each other; an iPhone listed them under More | The hidden 1 pt buttons that carry the shortcuts of menu-only commands were toolbar items, and the bar drew them | They are invisible `IOSAuthoringShortcutHosts`: the format-menu and toolbar-group hosts are a background of `IOSAuthoringKeyboardBar`; Find Next, Find Previous and Use Selection are a background of the document content in every layout, because the Find button (`⌘F`) stays in the navigation bar while the preview shows |
| Every relative image in a picked folder failed | The picker's folder URL ends in `/`. On a device, `AssetURLResolver`'s `resolvingSymlinksInPath()` is also expected to drop the leading `/private` that the picker URL keeps (`/private/var/mobile/...`); that part is from documented behaviour and was not observed | `IOSWorkspacePathAuthority.relativeSpelling(root:file:)`, which allows the root's trailing slash, used by the preview reader and the watcher. The watcher also drops a callback URL's own trailing slash, which a file presenter gives a folder child (`…/notes/`). When the plain spelling fails, both compare against the root with its symlinks resolved; the reader then rebuilds `location.fileURL` under `record.rootURL` for `authorize` |

Undo's symbol name was also misspelled (`arrow.uturn backward`); it never showed because
the bar it was on never showed.

## Why

The module suites drive controllers directly (`completePicker` with a live request, a
`TextField` host for the shortcut test, roots built from paths without a trailing
slash), and the hosted launch smoke only checks that the Files screen and its Open
control exist. Nothing had sent a real picker result, a real row tap or a real folder
URL through the composed app. The M0 owner report was on the prototype, not this app.

## Alternatives considered

- **Keep `pickerRequest` as the issuance and stop SwiftUI from clearing it** (a binding
  whose setter ignores `nil`). The sheet would then never dismiss on a swipe unless the
  delegate also reported a cancel, which UIKit does not promise.
- **Host the authoring controls in `inputAccessoryView`.** That keeps them glued to the
  keyboard but needs a hosting controller owned across EditorKitIOS and the app shell,
  and shows nothing with a hardware keyboard. A bottom row needs neither.
- **Keep the pane control in the navigation bar and move other items into the overflow.**
  The bar's choice of what to drop is the system's and changes with width and OS version.

## Limits

- Verified in iOS 27.0 simulators (iPhone 17 Pro; iPad Pro 11-inch for the layout, the
  bar and the navigation bar). No physical device and no iOS 26 runtime. Whether iOS 26 orders the sheet dismissal and the delegate the same way was
  not checked; the fix does not depend on the order.
- The recovery, conflict-copy and Insert Image → Files pickers are covered by unit
  tests of the new order, not by a UI run: reaching recovery/conflict needs a recovery
  draft and an external conflict.
- The `/private` spelling was not seen on a device. Tests reproduce the mismatch with a
  symlinked folder, for the preview reader and for the watcher's callbacks; device-pass H6
  is the first real check of the reader.
- The watcher's per-file notices were not observed in a UI run.
- Between a picker sheet's dismissal and its delegate's result, `pickerRequest` is nil
  while the issuance is live, so the guards that test `pickerRequest == nil` (Recent,
  Save a Copy) admit a presentation in that gap. How long the gap is was not measured.
  The later open is still checked by the existing origin and capture validation.
- With the bar mounted, `⌘Z` and `⇧⌘Z` are SwiftUI shortcuts beside the text view's own.
  In the simulator one `⌘Z` removed one typed run and `⇧⌘Z` restored it, through
  XCUITest's key events, not a physical keyboard.
- The bar is not shown while a single-pane layout shows the preview, so the formatting
  shortcuts are not installed there; the find shortcuts are. Switching to the preview resigns first responder on
  this scene's `editorHostView?.endEditing(true)` rather than app-wide, so a background
  scene on iPad cannot dismiss the key scene's keyboard. Switching panes during a Zhuyin
  composition was not tested (device-pass D7).
- No committed UI test drives the document picker. The walk used a temporary XCUITest;
  picker navigation by label is too dependent on the simulator's Files state to gate CI.
- `index.html` is copied verbatim by `preview-src/build.mjs`; the source and the
  committed copy were edited identically and `make preview-bundle` was not run.
- iOS PDF/Print export pagination was not re-tested after adding the viewport meta tag.
