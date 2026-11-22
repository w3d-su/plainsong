# iOS performance probe ships in the app, behind a hidden Settings row

Date: 2026-11-15. Step I3 of the iOS 1.0 close-out (`docs/release-1.0-scope.md` §3,
Performance row).

## Decision

- `AppIOS/Features/PerformanceProbe` is compiled into every `PlainsongIOS` build. It is
  reached from Settings by tapping the Version row five times, which reveals a
  Performance Probe button; the choice is stored in `UserDefaults`.
- The probe types into the open document with `UIKeyInput.insertText`, records each
  keystroke against the run loop and a `CADisplayLink`, measures preview renders, deletes
  what it typed, and checks the text equals the starting text. The report is JSON, shared
  through the system share sheet.
- Two diagnostics hooks are added, both nil outside a run:
  `IOSSourceEditorController.onHighlightApplied` and
  `PreviewController.renderTimingObserver` (`PreviewRenderTiming`). Neither is on the
  keystroke path. No frozen C0 contract file changes.
- The probe's commit time does not close the "keystroke to screen under 16 ms" budget by
  itself. It is the app's share of that time.

## Why

- The owner signs with a free Apple ID and installs a re-signed IPA, so Instruments
  cannot be assumed, and `docs/ios/handoffs/11-validation.md` asks for at least 60
  samples with raw values kept.
- Measuring the binary that ships avoids a second build whose numbers would have to be
  argued to carry over. A Debug build is slower; the report marks any non-Release run as
  not usable.
- The hooks exist because the two events have no other observable: the editor paints a
  highlight without publishing an event, and `renderCompleted` carries no send time, so
  the 150 ms debounce could not be separated from the render.

## What the numbers are

- `commit`: from just before `insertText` to the main run loop's before-waiting
  observer that runs after Core Animation's. Layout and drawing for the edit are done.
- `refresh`: the first display-link timestamp at or after that commit. A lower bound on
  when the glyph can be shown; the render server usually presents one refresh later.
- `highlight`: from the same start to the visible-range highlight being painted.
- `preview render`: hand-off to JavaScript to `renderComplete`, on PreviewKit's clock.

## Limits

- Light leaving the panel is not measured. That needs a camera.
- UIKit does not consult the text view delegate for a programmatic `insertText`. The
  editor's text view runs the same editing-behavior check in its `insertText` override,
  so the per-character work matches; the route into it is not the keyboard's.
- Marked-text composition (Zhuyin, Pinyin) is not exercised. A run types the letter `x`.
- File-open time is not measured.
- An iPhone display link is granted more than 60 Hz only when the app's Info.plist opts
  in, which it does not. The report records the granted frame interval.
- The run edits the document and its file is autosaved, so the probe is for disposable
  copies. Its keystrokes stay on the undo stack.
- Nothing here has run on a physical device. The tests drive the probe against a text
  view in a simulator window.

## Alternatives considered

- A compile-time flag producing a separate probe IPA: measures a different binary and
  needs its own archive path through `Scripts/ios`.
- XCTest performance tests on device: needs Xcode attached for every run, and XCUITest
  typing adds its own latency.
- MetricKit hitch data: arrives daily and aggregated, with no per-keystroke samples.
- Timing `textViewDidChange` alone: the handoff rules it out as not input-to-screen.
