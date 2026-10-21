# Lane 09 acceptance review fixes — 2026-10-13

Source commits: lane 08 `04015de35b3467dbc1074207531af50cf7a34941`, lane 09 `ee81abf042d685b21c6af78f93b96c5140c1841d`, based on `76af905fe7fc61d9f78869ff10b629f729dd4a1a`. Assigned worktree `/Users/davis._.su/.codex/worktrees/ios-review-authoring/blogeditor`, branch `codex/ios-authoring-review-fixes`. Frozen C0 ref remains `ios-c0-v1` = `642cb212703220409874a2741c5adbfb8c80fe8a`. Source fixes are additive; no history rewrite, push or PR creation was performed by this task.

## Fixed behavior

- Caller `Task.cancel()` is observed before import, after normalization/staging/validation, and immediately before synchronous source apply. Before accepted apply, no edit is accepted; an already staged owned leaf drains exactly one rollback in a noncancelled terminal task. Retained cleanup keeps the receipt and ownership identity instead of deleting another file. If cancellation occurs inside an already accepted apply, the accepted source edit still commits once.
- Payload policy still checks identity, MIME/extension and 10 MiB. It additionally requires an ImageIO container with complete status and successful immediate **first-raster decode**, including HEIC-transcoded PNG output. Signature-only and truncated fixtures never reach persistence. This does not claim decoding every frame of an animated image.
- Legacy valid fixtures now contain complete one-pixel PNG/JPEG/GIF/WebP bytes, rather than accepted header fragments. Seven Task-cancellation cases and four raster-validation cases extend the legacy 49-case suite to 60.

## Portable logic execution

Because native destination admission was unavailable, Root authorized a temporary Mac harness at `/private/tmp/ios-authoring-portable-20261013`. [Copy manifest](review-20261013/portable-copy-manifest.json) records 168 full-file source/dependency copies plus one exact Foundation-only final enum fragment from `IOSImagePickers.swift` (compiler imports added). Production/frozen Swift sources were byte-verified. Only two temporary dependency manifests add macOS 14 platform metadata; candidate package files were unchanged. Yams resolved to 6.2.2. UIKit Photos/Files picker adapters, Photos loader/image view, production app entrypoint/composition, and six App-host resource contract consumers were excluded. Authoring SwiftUI declarations compiled without executing UI. Existing private controlled editor/writer doubles own every operation port; no fake-success native provider was supplied.

Under the canonical lock, `swift test` completed at **2026-10-13 13:47:55.688 CST**, child/wrapper exit 0: **149 XCTest executed, 149 passed, 0 failed, 0 skipped**. The separate Swift Testing footer reported 0 and is not counted. [All named cases](review-20261013/portable-positive-cases.json).

| Scope/class | Executed |
|---|---:|
| Authoring total | 89 |
| IOSImageInsertionOrderingTests | 5 |
| IOSImageInsertionPathTests | 5 |
| IOSImageInsertionPolicyTests | 7 |
| IOSImageInsertionStaleTests | 17 |
| IOSImageInsertionTerminalTests | 15 |
| IOSImageRasterValidationTests | 4 |
| IOSImageTaskCancellationTests | 7 |
| Images total | 60 |

## Controlled negative proof

In task-owned harness copies only, remove the exact-source Find delivery guard, bypass caller Task cancellation observation, and bypass raster decode. Run the two pending-source Find cases, staged cancellation, signature-only/truncated raster cases, and accepted-commit control. The final attempt executed **6 cases: 5 expected FAIL, 1 control PASS**. The test child exited **1**; the Python wrapper's exit 0 proves only that `finally` restored all mutated source hashes. XCTest's 76 assertion failures are not 76 cases. [Named outcomes](review-20261013/portable-negative-cases.json), [before hashes](review-20261013/portable-negative-before.json), [restored hashes](review-20261013/portable-negative-restored.json). The subsequent full 149-case run passed with restored bytes.

The failures cover both same-revision/raw-Unicode Find deliveries, `testTaskCancelDuringStageDrainsOneOwnedRollback`, `testSignatureOnlyRastersNeverReachPersistence`, and `testTruncatedRealRastersNeverReachPersistence`. `testTaskCancellationInsideAcceptedApplyStillCommitsOnce` passed under the mutation, preserving the accepted-commit rule.

Earlier attempts are retained, not silently replaced: portable negative attempt1 executed 0 because temporary dependency deployment metadata defaulted below macOS 14; only harness manifests were corrected. Attempt2 executed 6 and all failed: five intended failures plus a new test's observation error, which expected editor `apply` in the writer-only event log. The test now checks the shared probe's `stage/validate/apply/commit`, writer's `stage/validate/commit`, one submitted edit, one commit and zero rollbacks; attempt3 and the restored positive run verify that correction. [Raw evidence inventory with hashes](review-20261013/raw-evidence-inventory.json).

## Actual iOS compilation and failed runtime attempts

The final generic iOS command, under `/private/tmp/plainsong-xcodebuild-test.lock`, was:

```sh
xcodebuild -project Plainsong.xcodeproj -scheme PlainsongIOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/ios-authoring-review-dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
```

`/private/tmp/ios-authoring-review-build-for-testing-3-20261013.log`: exit 0, **TEST BUILD SUCCEEDED**, arm64 and x86_64 simulator slices, deployment iOS 26. **155 scoped named App cases compiled** (89 Authoring + 60 Images + 3 Authoring contract consumers + 3 Persistence asset contract consumers); **0 native cases executed**. Other scheme dependencies compiled as required; their compilation is not counted as executed tests. Generic attempts1/2 were exit 75 lock-admission failures and did not start Xcode. Production source bytes were compared against the 339-input snapshot after this successful compilation.

The inherited Oct9 follow-up log was empty and its results bundle absent; the old original 49-case receipt is not current review evidence. On Oct13, the 66-case native image/contract selection compiled then stalled in CoreSimulator `installApplication`, with no test case started. After about 10 minutes only this task's driver was interrupted, with Root's authorization; the results finalize as interrupted. Its outer exit 75 followed an admitted run, so it is **not** a lock-admission failure. A thread sample was retained; the root cause is not established.

One task-owned shared iPhone 17 / iOS 27 device was created and booted successfully in 43 seconds: `A24A1CB9-2861-4AA4-A79F-E53F768950D8`. Original devices were preserved; Root owns shared-device cleanup. Native negative attempts1/2 still failed concrete destination discovery, exit 70/0 executed. Attempt2 explicitly used `-sdk iphonesimulator`; that flag did not resolve admission and is not claimed as the cause. Candidate mutation files were restored with [before](review-20261013/native-negative-before.json)/[after](review-20261013/native-negative-restored.json) hashes. Active tools selected `/Applications/Xcode-beta.app`, Xcode 27.0 `27A5194q`, available iOS 27.0 runtime `24A5355p`; no global service reset or unrelated job was killed. No further native infrastructure retries were performed.

## Final source and formatting provenance

[Final input manifest](review-source-inputs-20261013.json) contains **339 inputs**, including all AppIOS/AppIOSTests Swift, shared package Sources/manifests, committed preview resources, `project.yml`, and `.swiftformat`. It records final source commits, per-file SHA-256 and a digest of the sorted input inventory. Four Authoring files were wrapped after proof with SwiftFormat 0.62.1 and verified identical quoted-literal/non-whitespace tokens; one image-normalizer documentation comment was clarified to say complete container and first-raster decode, with every other byte identical. These five explicitly recorded nonsemantic deltas are the only final-source differences from the successful proof snapshot; no post-proof logic change was made.

Exact repo `.swiftformat`, SwiftFormat **0.62.1**: final **0/38 owned Swift files require formatting**; `git diff --check` passed. A SwiftLint command unexpectedly honored full-repository `included` paths and produced existing warnings, including Authoring complexity/body-length/SwiftUI trailing-closure warnings. It is retained as warning-bearing evidence, not a clean scoped lint result.

## Open acceptance gates

This is **portable Mac logic PASS + generic iOS compile PASS**. Current iOS runtime execution, production coordinated filesystem/native writer/Undo integration, real Photos/Files/iCloud provider behavior, image display in authorized preview, background behavior, Chinese IME, external keyboard, VoiceOver, iPhone/iPad, self-signed installation, M0 and measured performance remain OPEN. The private fake's Undo is not native Undo acceptance. Root owns aggregate integration, exact-head CI, Decision Log and publication. No shared package, frozen contract, app state, editor/history, project definition or owner checkout was changed by this task.
