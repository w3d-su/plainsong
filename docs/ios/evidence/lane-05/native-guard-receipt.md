# Lane 05 native guard proof — 2026-10-13

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Final reviewed source: `edfbb5c67fd95a49238c66b61eefc9d0eec9bccd` on `codex/ios-storage-review-fixes`. The prior generic 46-case compile and historical 41-case native run retain their original version boundaries. This additive verification executes the final 46-case source and six controlled counterexamples; it changes only lane-05 evidence and runner metadata.

## Scope and source seal

All mutations occur in the task-owned copy `/private/tmp/plainsong-storage-six-guards-20261013-native/probe-source`; no managed production source, root integration source, provider, Mac source, other lane, or frozen contract was mutated. Four local package graphs resolve to that copy; Yams resolves to `6.2.2`. The 148 manifests/Swift source/test inputs exactly equal the prior sealed lane manifest before preparation and after every mutation. Each mutated file's original, mutation, and restored SHA-256 is retained in [native-guard-proof.json](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-05/native-guard-proof.json), together with the complete input checks.

Against immutable Root head `c1c250a2b5c3e518108356b0c598064d4d1b0bb4`, all **117 storage runtime-associated inputs match**: WorkspaceKitIOS 35, MarkdownCore 76, WorkspaceCore 3, and PreviewKit manifest plus the two PreviewKitContracts product sources 3. Full 148-input comparison is **138 equal / 10 different**, with all ten differences in the full PreviewKit port/tests; those files are outside this scheme's PreviewKitContracts dependency. This receipt does not call all 148 aggregate inputs equal. All **13 frozen hashes match** in lane and Root. No source changed during this verification, and the previous pinned SwiftFormat 0.62.1 / 26-file lint remains source-bound evidence; this docs-only follow-up did not rerun macOS SwiftPM tests or SwiftFormat.

The prior final46 `.xctestrun` confirms scheme `WorkspaceKitIOS` has an enabled `WorkspaceKitIOSTests` test target. New native results independently confirm all selected cases actually executed. Missing tests, 0-run, skipped cases, build failures, and admission failures cannot satisfy a probe.

## Actual native execution

Destination: task-owned shared iPhone 17 simulator `A24A1CB9-2861-4AA4-A79F-E53F768950D8`, arm64, iOS 27.0 build `24A5355p`. This is simulator component evidence, not a physical device or production-composition claim. Run interval: `2026-10-13T08:28:04.237840+00:00` through `2026-10-13T08:31:10.444898+00:00`.

| Run | Owned launcher/process-group PID | Exit | Actual XCTest result | Restore |
|---|---:|---:|---|---|
| `close-autosave-resumption` | 15359 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `external-barrier` | 15818 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `post-close-revision` | 16063 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `retirement-drain` | 16295 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `retirement-read-admission` | 16522 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `late-retirement-recovery` | 16750 | 65 | 1 named failed / 0 passed / 0 skipped | all 148 equal |
| `restored-module` | 17004 | 0 | 46 passed / 0 failed / 0 skipped | all 148 equal |

The six exit-65 negative results are intentional **named assertion failures**, not successful feature runs or infrastructure errors. Their exact names/failure texts, command arrays, xcresult paths, PID role, timestamps, and timeout fields are in the proof JSON. Failure semantics were checked against the retained raw logs:

- `close-autosave-resumption`: autosave generation 1 was not greater than 1; restored authority did not schedule a fresh task.
- `external-barrier`: one original-file write occurred while the external read was pending.
- `post-close-revision`: close retired a newer unsaved draft.
- `retirement-drain`: provider close began with one write still in flight.
- `retirement-read-admission`: retiring port admitted a new external read after its existing reads were drained.
- `late-retirement-recovery`: latest source/revision recovery assertion failed at IOSDocumentRetirementTests.swift:48.

Every probe restores its bytes in `finally` and verifies the full 148-input fingerprint before the next mutation. The final module result is **46 unique named Passed cases**, exactly matching `autosave-review-declared-tests.json`, with 0 failures/0 skips. Total controlled executions are six negative cases plus 46 restored positive cases = **52**, separate from Root's aggregate 294 cases.

Compressed raw logs `native-<label>-1.log.gz` are adjacent; their compressed and uncompressed SHA-256 values are retained in the proof. Original xcresults and detailed named-test JSON remain under `/private/tmp/plainsong-storage-six-guards-20261013-native/` as `<label>-1.xcresult` and `<label>-1-tests.json`.

## Reproduction and process bounds

```sh
python3 /Users/davis._.su/.codex/worktrees/ios-review-storage/blogeditor/docs/ios/evidence/lane-05/run-review-negative-probes.py \
  --source /Users/davis._.su/.codex/worktrees/ios-review-storage/blogeditor \
  --output /private/tmp/plainsong-storage-six-guards-20261013-native \
  --device A24A1CB9-2861-4AA4-A79F-E53F768950D8 \
  --expected-count 46 --operation-timeout 600
```

The proof records the runner source SHA and exact commands. Use a fresh task-owned output directory for new execution; the original command above resumes the retained run and deliberately skips already accepted records. Every command serializes through `/private/tmp/plainsong-xcodebuild-test.lock` using bounded 45-second admission, `-sdk iphonesimulator`, a task-owned DerivedData/result bundle, no parallel testing, 60-second per-test execution allowance, and a 600-second outer timeout. **0 outer timeouts; no owned-child termination or simulator/service cleanup was needed.** Launcher PID and process-group ID identify the runner-owned lockf launch/child group; they are not claimed as XCTest process IDs.

The probe runner uses `-collect-test-diagnostics never` to reduce diagnostic collection for intentional negative runs; its restored component run uses the same policy. This differs from the public `make ios-test` runner's **on-failure** policy. Retained assertion logs/named xcresult results are the mutation evidence; diagnostic-policy equivalence is not claimed. The public runner's stricter collection is preserved.

## Root aggregate cross-check and remaining gates

Read-only review of Root's sealed `c1c250a2b5c3` public `make ios-test` result found **294 unique named Passed cases**, 0 failed/0 skipped, with gate cases exactly equal to parsed xcresult test nodes. All **46/46** storage names and original **17/17** audit/control names actually Passed. The proof retains those selected statuses, sealed gate/results/named-file hashes, simulator metadata, and the original aggregate output path. Root owns central receipts, aggregate runtime/CI status, and integration.

Real Files/iCloud and bookmarks/provider coordination, physical IME/Undo, background transitions, iPhone/iPad coverage, device performance, and re-signed IPA installation/M0 gates remain **OPEN**. Lane 06 real providers and lane 13 production composition remain unavailable. PreviewKit's separate failing full-package run is not covered by this storage scheme or this receipt. No push, PR, merge, or owner-checkout mutation was performed.
