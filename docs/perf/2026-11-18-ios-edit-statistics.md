# iOS word counts after five rapid edits

On November 18, 2026, the iPhone 17 Pro simulator running iOS 27.0 started 15
full-document edit counts in three bursts at `5204ca21` (PR #276). Twelve
finished after a newer edit. At `33f3bcaa`, the same bursts started three
counts. All three belonged to the final revision. The one-count-per-burst
regression check passed in every run.

| Run | Baseline counts started | Baseline stale at completion | Fixed counts started | Fixed stale at completion | Fixed final word count |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 4 | 1 | 0 | 227,521 |
| 2 | 5 | 4 | 1 | 0 | 227,521 |
| 3 | 5 | 4 | 1 | 0 | 227,521 |

## What the test measures

Both builds used Release, native arm64, Xcode 27.0 (27A5194q) and a MacBook Pro
with an M1 Pro running macOS 27.0. Each iteration attached a fresh UIKit editor
to 1,048,552 UTF-8 bytes of Traditional Chinese Markdown, put the caret at the
start and called `insertText("甲")` five times. The source and session reached
revision 5 synchronously. Each test checked the exact final source and compared
the session's character, word and line counts with an independent full count.

The totals cover only the edit-triggered scans. The synchronous initial count
and the final reference count are outside the probe. In the baseline, each
`PHONE COUNT` records a completed scan and each `PHONE RESULT` records its
revision alongside the live revision. All five jobs finished in every run.
In the fixed build the probe records entry to the production counter and checks
the live version on return. The test joins all five scheduled tasks, including
those cancelled during the 300 ms pause.

In the three full-suite repeats at `33f3bcaa`, five native insertions and the
test's task-handle capture took 34.65, 16.26 and 16.82 ms. This interval ends
before the debounce and excludes display presentation. The baseline probe only
timed the counts. Physical keyboard and device display latency remain unmeasured.

## Regression coverage

All 44 EditorKitIOS tests passed in each of three Release iterations (132
executions). The small-document tests use a gate to release the pending work
and await the actual tasks. They cover immediate text and version updates, the
final statistics snapshot, cancellation inside a running worker, a late result
when two documents have identical source and version, detach and host teardown,
reattachment to an interrupted session, and a URL change before publication.
The cancellation test pauses a worker after entry, supersedes it with another
edit, then calls the production counter in that same task and requires a
`nil` result. A separate test holds a completed result until another document
is attached and verifies that its previous metrics survive the late delivery.
The shared MarkdownCore suite passed all 406 tests, including a deferred edit
that finishes with the same metrics as the previous revision.
In the Debug iOS app scheme, all 13 status-bar and shell tests and all 5
document observation barrier tests passed (`status-bar.xcresult`).

The repository-wide `make test` run passed the Swift package tests. Its macOS
hosted action exited with three failures. Two Find UI tests reported a
`testmanagerd` crash and the 512 KiB workspace search measured 151.554 ms
against a 150 ms budget. All three passed in a serial retry of the same build.
The search measured 44.059 ms. See `make-test.log` and `mac-retry.xcresult` in
the evidence directory below. All 231 preview tests passed separately, and
`make lint` passed.

## Reproduction

Use separate checkouts for `5204ca21` and `33f3bcaa`. Apply the baseline-only
probe in the former. [Baseline probe](2026-11-18-ios-burst-baseline.patch)

Generate the same narrow Release test scheme in each checkout from its root.

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

Use the simulator UUID from `xcrun simctl list devices available` and a fresh
result path for each run. Set the test identifier to
`IOSSourceEditorInputTests/testProfileBurstStatistics` for the baseline and
`IOSEditorStatisticsTests/testOneMiBTraditionalChineseBurst` for the fix.

```sh
xcodebuild -project Plainsong.xcodeproj -scheme ProfileEditorIOS \
  -configuration Release -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  "-only-testing:EditorKitIOSTests/$TEST_IDENTIFIER" -test-iterations 3 \
  ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$RESULT_PATH" test
```

Omit `-only-testing` to repeat the entire editor bundle. The review machine
retains the original measurements under
`/private/tmp/plainsong-perf-next.KY6Hau/` and the new logs and XCTest result
bundles under `/private/tmp/plainsong-ios-burst-evidence/`. Both the retained
baseline binary (`before`) and a clean rebuild with the linked probe
(`baseline-rebuild`) produced 5 starts and 4 stale results per burst.
`after` contains the isolated fixed burst and `verified` contains the full
three-iteration run at the recorded commit.
