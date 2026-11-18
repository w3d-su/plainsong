# iOS word counts after five rapid edits

- Date: 2026-11-18
- Commit: the commit that adds this revision of the file, on top of `379e9370`. The
  baseline is `5204ca21` (PR #276).
- Environment: iPhone 17 Pro simulator, iOS 27.0, on an M1 Pro MacBook Pro with macOS 27.0
  and Xcode 27.0 (27A5194q). Release, native arm64, `ENABLE_TESTABILITY=YES`. The counting
  benchmark ran on the same Mac as a macOS command-line program built with `swiftc -O`.
- Fixture: 1,048,552 UTF-8 bytes of Traditional Chinese Markdown, built by
  `IOSEditorStatisticsTests.testOneMiBTraditionalChineseBurst`. The test puts the caret at
  the start and calls `insertText("甲")` five times. Counting runs off the main actor, so
  no §12 budget applies.
- Procedure: three iterations of that Release test for each build, with the temporary
  probe for that build applied (both probes are below). The benchmark ran 10 interleaved
  pairs.
- Result: **PASS**, one count per burst. The baseline started 15 counts in three bursts,
  and 12 of them finished after a newer edit. This commit started 3 counts, one per
  burst, each for revision 5, and none was stale. In the benchmark, counting a 1 MiB
  text storage string took a median of 154.9 ms before this commit and 102.4 ms after it,
  with the same counts in every pair.

| Run | Baseline counts started | Baseline stale at completion | Counts started | Stale at completion | Applied at revision |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 4 | 1 | 0 | 5 |
| 2 | 5 | 4 | 1 | 0 | 5 |
| 3 | 5 | 4 | 1 | 0 | 5 |

## What changed

In the baseline every edit started a detached count, and each result was dropped
unless the revision still matched. Now the iOS editor calls
`DocumentSession.scheduleStatisticsRefreshAfterEdit`, which the macOS editor already
uses. The session owns one pending count behind a 300 ms pause, and each edit cancels
the previous count. Detaching or closing the editor leaves the count with its
document. The editor starts no count while text is marked, and counts the composed
text once the composition ends.

The test checks outcomes that do not depend on how long the five insertions take:
the first four tasks are cancelled, and the session applies one value, equal to an
independent count of the final source. Which counts started is measured only by the
probe.

## Counting the editor's string

UIKit's text storage string is a bridged (foreign) Swift string. Counting it walks
Swift's slow path for foreign strings. `TextStatistics.countUnlessCancelled` now
counts an exact native UTF-8 copy (`ExactSourceText.nativeCopy`) when the source is
not native. Native sources, such as the macOS editor's, are counted as they are.

The benchmark below counted 1,048,567 bytes from an edited `NSTextStorage`. Before
this commit, `TextStatistics(text:)` took 177.3, 157.1, 156.1, 154.4, 153.7, 156.4,
154.7, 154.3, 155.1 and 154.1 ms. The new `countUnlessCancelled`, including the copy,
took 101.5, 104.0, 102.5, 102.0, 103.0, 103.2, 101.8, 103.3, 102.4 and 102.3 ms. The
order alternated in each pair. The one-minute load average was 109.9 before the run and
93.2 after it.

The simulator probe also timed each count at utility priority. Runs with the native
copy took 154, 118 and 2,841 ms. Runs with it removed took 580, 263 and 2,477 ms. The
spread within each build is larger than the difference between them, so the evidence
for the copy is the benchmark.

## Regression coverage

At this commit, all 47 EditorKitIOS tests passed in Release, and 410 MarkdownCore
tests passed with `swift test`. The new tests cover:

- the burst;
- a count that survives detach;
- reattachment, which keeps the pending count instead of restarting it;
- a late count when another document has the same source and version;
- host teardown;
- Shift-Tab after teardown;
- synthetic Zhuyin composition committed through `unmarkText` and through `insertText`;
- detach during composition.

Synthetic `setMarkedText` calls do not exercise a device keyboard.

The Shift-Tab and Zhuyin tests failed after their fixes were removed. In the Debug iOS
app scheme, all 13 `IOSShellChromeTests`, all 35 `IOSDocumentSceneControllerTests` and
all 5 `IOSDocumentObservationBarrierTests` passed.

## Reproduction

Generate a narrow Release test scheme from the checkout root.

```sh
cat > profile-editor.yml <<'EOF'
include: [project.yml]
schemes:
  ProfileEditorIOS:
    build:
      targets:
        PlainsongIOS: all
    test:
      targets:
        - package: EditorKitIOS/EditorKitIOSTests
          parallelizable: false
EOF
xcodegen generate --spec profile-editor.yml
```

Take the simulator UUID from `xcrun simctl list devices available`. The test
identifier is `IOSSourceEditorInputTests/testProfileBurstStatistics` for the baseline
and `IOSEditorStatisticsTests/testOneMiBTraditionalChineseBurst` for this commit.
Omit `-only-testing` and `-test-iterations` to run the whole editor bundle.

```sh
xcodebuild -project Plainsong.xcodeproj -scheme ProfileEditorIOS \
  -configuration Release -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  "-only-testing:EditorKitIOSTests/$TEST_IDENTIFIER" -test-iterations 3 \
  ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$RESULT_PATH" test
```

The baseline probe, applied to `5204ca21`:

```diff
--- a/Packages/EditorKitIOS/Sources/EditorKitIOS/Editor/IOSSourceEditorController+Mutation.swift
+++ b/Packages/EditorKitIOS/Sources/EditorKitIOS/Editor/IOSSourceEditorController+Mutation.swift
@@ -209,7 +209,9 @@
         // Count off the main actor; drop the result if the session's version or text
         // changed before it returns to the main actor.
         Task.detached(priority: .utility) { [weak self] in
+            let started = DispatchTime.now().uptimeNanoseconds
             let statistics = TextStatistics(text: current)
+            print(String(format: "PHONE COUNT version %d %.2f ms", version, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
             await self?.republishDeferredStatistics(statistics, version: version, text: current)
         }
     }
@@ -220,6 +222,8 @@
         text: String
     ) {
         guard let session = installation?.session else { return }
+        Self.profileCountFinishes += 1
+        print("PHONE RESULT", version, "live", session.version)
         guard session.version == version, ExactSourceFragment.matches(session.text, text) else { return }
         guard session.availableStatistics != statistics else { return }
         session.applyStatistics(statistics)
--- a/Packages/EditorKitIOS/Sources/EditorKitIOS/Editor/IOSSourceEditorController.swift
+++ b/Packages/EditorKitIOS/Sources/EditorKitIOS/Editor/IOSSourceEditorController.swift
@@ -5,6 +5,7 @@
 /// Native UITextView writer. Authoring and image mutations enter only through `apply`.
 @MainActor
 public final class IOSSourceEditorController: NSObject, IOSSourceEditorBinding, UITextViewDelegate {
+    static var profileCountFinishes = 0
     public let textView: IOSMarkdownTextView
     public private(set) var isContentVisible = true
     public var theme: IOSEditorTheme {
--- a/Packages/EditorKitIOS/Tests/EditorKitIOSTests/IOSSourceEditorInputTests.swift
+++ b/Packages/EditorKitIOS/Tests/EditorKitIOSTests/IOSSourceEditorInputTests.swift
@@ -4,6 +4,24 @@
 import XCTest

 final class IOSSourceEditorInputTests: XCTestCase {
+    @MainActor
+    func testProfileBurstStatistics() async throws {
+        let paragraph = "## 草稿\n\n我們在寫一份繁體中文的技術文件，內容包含 Unicode、標點與數字 123。\n\n"
+        let original = String(repeating: paragraph, count: 1_048_576 / paragraph.utf8.count)
+        let harness = IOSEditorHarness(text: original)
+        IOSSourceEditorController.profileCountFinishes = 0
+        harness.placeCaret(at: 0)
+        for _ in 0 ..< 5 { harness.textView.insertText("甲") }
+        XCTAssertEqual(harness.session.version, 5)
+        let deadline = ContinuousClock.now + .seconds(20)
+        while IOSSourceEditorController.profileCountFinishes < 5 && ContinuousClock.now < deadline {
+            try await Task.sleep(for: .milliseconds(20))
+        }
+        XCTAssertEqual(IOSSourceEditorController.profileCountFinishes, 5)
+        XCTAssertEqual(harness.session.text, "甲甲甲甲甲" + original)
+        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: harness.session.text))
+    }
+
     @MainActor
     func testTextKit2SurfaceAcceptsTraditionalChineseEmojiAndPasteOnceEach() {
         let harness = IOSEditorHarness(text: "")
```

The probe for this commit. It is not committed.

```diff
--- a/Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift
+++ b/Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift
@@ -116,11 +116,23 @@
         cancelStatisticsTask()
         let source = text
+        let probeVersion = version
         statisticsTask = Task.detached(priority: .utility) { [weak self] in
             if debounced {
                 do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
             }
-            guard let counts = TextStatistics.countUnlessCancelled(source) else { return }
+            let probeStart = DispatchTime.now().uptimeNanoseconds
+            print("PHONE COUNT START", probeVersion)
+            guard let counts = TextStatistics.countUnlessCancelled(source) else {
+                print("PHONE COUNT CANCELLED", probeVersion)
+                return
+            }
+            print(String(format: "PHONE COUNT DONE %d %.2f ms", probeVersion,
+                         Double(DispatchTime.now().uptimeNanoseconds - probeStart) / 1e6))
             await MainActor.run { [weak self] in
-                guard !Task.isCancelled, let self else { return }
+                guard !Task.isCancelled, let self else {
+                    print("PHONE COUNT STALE", probeVersion)
+                    return
+                }
+                print("PHONE COUNT APPLIED", probeVersion, "live", self.version)
                 statisticsTask = nil
                 applyStatistics(counts)
```

To run the benchmark, save the program as `main.swift` next to copies of
`TextStatistics.swift` and `ExactSourceText.swift` from
`Packages/MarkdownCore/Sources/MarkdownCore`. Build it with
`swiftc -O -module-name MarkdownCoreBench main.swift TextStatistics.swift ExactSourceText.swift`.
For the "before" column, the benchmark calls the unchanged `TextStatistics(text:)`
initializer.

```swift
import AppKit
import Foundation

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
let paragraph = "## 草稿\n\n我們在寫一份繁體中文的技術文件，內容包含 Unicode、標點與數字 123。\n\n"
let original = String(repeating: paragraph, count: 1_048_576 / paragraph.utf8.count)
let storage = NSTextStorage(string: original)
storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "甲甲甲甲甲")
let bridged = storage.string
precondition(bridged.utf8.withContiguousStorageIfAvailable { _ in true } == nil, "expected a foreign string")
let clock = ContinuousClock()
var before = [Double](), after = [Double]()
for pair in 0 ..< 10 {
    for path in (pair.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
        let source = storage.string
        let start = clock.now
        let counts = path == 0 ? TextStatistics(text: source) : TextStatistics.countUnlessCancelled(source)!
        let elapsed = ms(start.duration(to: clock.now))
        precondition(counts == TextStatistics(text: original.isEmpty ? "" : "甲甲甲甲甲" + original))
        if path == 0 { before.append(elapsed) } else { after.append(elapsed) }
    }
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return (s[4] + s[5]) / 2 }
print("bytes", bridged.utf8.count)
print("bridged TextStatistics(text:) ms:", before.map { String(format: "%.1f", $0) }.joined(separator: " "))
print("countUnlessCancelled (native copy) ms:", after.map { String(format: "%.1f", $0) }.joined(separator: " "))
print(String(format: "median before %.1f ms, after %.1f ms", median(before), median(after)))
```

## Evidence

The logs and XCTest result bundles are under
`~/Documents/PlainsongPerformanceEvidence/ios-edit-statistics-2026-11-18/` on the
measuring Mac. `baseline-5204ca21` holds the baseline runs. `first-revision-33f3bcaa`
holds the runs for this PR's first revision, which counted in the editor controller.
`session-count` holds the runs above: `editor-suite`, `burst-native`,
`burst-bridged` (the probe with the native copy removed), `ios-app-statistics`,
`mutation-check` and `count-bench`.
