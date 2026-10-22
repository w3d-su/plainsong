# Lane 08 acceptance review fixes — 2026-10-09

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Worktree: `/Users/davis._.su/.codex/worktrees/ios-review-authoring/blogeditor`.
Branch: `codex/ios-authoring-review-fixes`.
Local starting commit: `8875de5cfb9e7ced54c0f7a9cedbadf982e04c65`, combining original lane 08 `501f6fea213993feb1e98d04c3ecc0ab73aa499a` and lane 09 `912aad7cf9f8d34f2de270fbc984742cc15f606a`. Frozen contracts remain `ios-c0-v1` (`642cb212703220409874a2741c5adbfb8c80fe8a`). Original lane worktrees/PRs were not changed or merged. This receipt belongs to the same additive commit as the lane 08 fixes.

## Fixed behavior

- Accepted Find retains binding ID, document identity/revision, and exact raw source. Next/Previous/Replace first verify that context against the current editor snapshot. A same-length native source change or document/binding switch schedules a fresh query and does not reveal or replace an old range. No replacement is automatically retried. Existing UTF-16 planner, actual match range, composition and focus guards remain in use.
- The production scheduler has one running synchronous detached scan and one replaceable latest pending request. Cancelling/superseding a scan invalidates its delivery; the running worker drains before the next worker starts. Private fakes still test controller sequencing, and three new tests exercise the real scheduler with parked workers, recorded invocation order, off-main execution, and a `maxRunning == 1` assertion.
- Frontmatter uses the current source projection and an immutable editor binding observation. Native edit/Undo, document switch, malformed source, and detach update the displayed projection without writing source. Typed drafts remain separate and retain their original authorization; a draft from another document/binding cannot be applied to the newly displayed document. Discard explicitly removes the retained draft. Add re-parses the current source and refuses an existing or malformed block.

No EditorKitIOS/history, MarkdownCore, shared contract, package, project, shell, persistence or global documentation changes were made. Native Undo-after-revocation was already a passing root counterexample and is not treated as a bug here.

## Executed validation

Xcode 27 SDK; iPhone 17 simulator runtime iOS 27.0, UUID `00FE8F01-CC81-4A3D-B319-19DBBD84F4A4`; signing disabled. One shared `lockf` wrapper covers generation and the Xcode run. Derived data `/private/tmp/ios-authoring-review-dd`; result `/private/tmp/ios-authoring-review-08-results.xcresult`; log `/private/tmp/ios-authoring-review-08-test.log`; generation log `/private/tmp/ios-authoring-review-generate.log`.

```sh
/usr/bin/lockf -k /private/tmp/plainsong-xcodebuild-test.lock /bin/zsh -c '
set -e
xcodegen generate > /private/tmp/ios-authoring-review-generate.log
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=00FE8F01-CC81-4A3D-B319-19DBBD84F4A4" \
  -derivedDataPath /private/tmp/ios-authoring-review-dd \
  -resultBundlePath /private/tmp/ios-authoring-review-08-results.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PlainsongIOSTests/IOSAuthoringGuardedEditTests \
  -only-testing:PlainsongIOSTests/IOSFormattingActionTests \
  -only-testing:PlainsongIOSTests/IOSFrontmatterPanelTests \
  -only-testing:PlainsongIOSTests/IOSFindGenerationTests \
  -only-testing:PlainsongIOSTests/IOSSingleReplaceTests \
  -only-testing:PlainsongIOSTests/IOSAcceptedFindProtectionTests \
  -only-testing:PlainsongIOSTests/IOSFrontmatterProjectionTests \
  -only-testing:PlainsongIOSTests/IOSProductionFindSchedulerTests \
  -only-testing:PlainsongIOSTests/AuthoringContractConsumerTests \
  -only-testing:PlainsongIOSTests/PersistenceAssetContractConsumerTests \
  test > /private/tmp/ios-authoring-review-08-test.log 2>&1
'
```

**93 executed tests, zero failures; exit 0 and `TEST SUCCEEDED`.** Test cases completed at 2026-10-09 14:57:55 CST. Xcode then attempted simulator diagnostics; that collection timed out after 600 seconds and the runner sealed the successful result at 15:07:56 CST. The optional diagnostic collection is incomplete. The timeout is not counted as a failed test or as successful hardware/provider evidence.

| Class | Executed |
|---|---:|
| IOSAuthoringGuardedEditTests | 9 |
| IOSFormattingActionTests | 18 |
| IOSFrontmatterPanelTests | 16 |
| IOSFindGenerationTests | 17 |
| IOSSingleReplaceTests | 13 |
| IOSAcceptedFindProtectionTests | 5 |
| IOSFrontmatterProjectionTests | 6 |
| IOSProductionFindSchedulerTests | 3 |
| AuthoringContractConsumerTests | 3 |
| PersistenceAssetContractConsumerTests | 3 |

SwiftFormat 0.62.1 lint: 0/19 owned Authoring Swift files require formatting; `git diff --check` passes. This run compiled the existing targets required by the scheme but executed only the listed classes; it is not a full Mac or iOS package run.

## Evidence boundary

The actual production Find scheduler executes in the three named scheduler tests. Editor mutation tests use the private frozen-protocol fake; the observer test uses a private frozen-protocol binding adapter. This does not execute lane 04's real native writer/Undo stack or lane 10 command installation. True Chinese IME, external keyboard, VoiceOver, production document/provider composition, real iPhone/iPad, M0 and performance gates remain OPEN. Root owns integration/publication and exact-head Mac CI; none was run or pushed by this task.
