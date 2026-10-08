# C0 verification — lane 13

Date: 2026-10-08 (Asia/Taipei). IOS-C0-v1. Worktree: `/private/tmp/plainsong-ios-integration`; owner checkout was never edited, switched, stashed, formatted or generated. Initial source: packet `2144c46c888360c84a42fef79e676e60b518048b`, live main `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2`.

## Reproduction

```sh
PATH=/path/to/swiftformat-0.62.1:$PATH make lint
PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock \
  CI=1 /usr/bin/lockf -k /private/tmp/plainsong-xcodebuild-test.lock make test
/usr/bin/lockf -k /private/tmp/plainsong-xcodebuild-test.lock make build
make test-portable-core
make ios-c0-build
# Only with an actual installed iOS 26+ simulator UUID:
IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>' make ios-c0-test
```

The iOS bootstrap owns the outer lock; do not wrap it in the same lock. `make build/test/release` remain Mac entries; new portable checks target only macOS-compatible SyntaxKit/WorkspaceCore. `ios-c0-build` builds all tests without running them and verifies every committed preview resource SHA-256. It is not an IPA or a runtime smoke PASS. SDK 27 was available; no simulator runtime/device was installed.

## Named contract cases

- IOSDocumentContractTests: different open instances at the same version; older saved capture retains newer live source/version/dirty state.
- SyntaxContractConsumerTests: request identity/version and absolute UTF-16 ranges across Chinese/emoji.
- WorkspaceContractTests: exact Unicode spelling and opaque resource bytes.
- EditorContractConsumerTests: unavailable editor cannot invent source or reveal a range.
- DocumentStateContractTests: opening/conflict/unavailable/closed fence writing while retaining generation.
- AuthoringContractConsumerTests: independent synchronous command consumer forwards binding/revision/generations, zero source/selection side effects on refusal; C0 has no providers; shared preview resources nonempty.
- PersistenceAssetContractConsumerTests: independent store/resource consumer gets typed failure; lease/coordination/asset seams conform and cannot invent successful persistence.

12 iOS-selected cases compile, 0 execute here. The four Mac package suites, Mac app/UI/performance tests, Python tooling and JS suite execute; detailed counts are in the ledger. `frozen-contracts.json` records 13 source hashes and 71 unique declarations.

## Retained local attempts

- Mac attempt 1: `/private/tmp/plainsong-ios-c0-mac/run.log`; MarkdownCore 322 passes, EditorKit 453 / 7 skips / four architecture assertions fail because pre-iOS exact inventory omitted C0 packages/targets/dependencies. No executor or input failure.
- Mac attempt 2: `/private/tmp/plainsong-ios-c0-mac-attempt2/run.log`; the updated inventory passes; a new test selected the same-named scheme instead of the app target. Its single assertion fails. Corrected the section selector; all five focused architecture tests pass.
- Mac attempt 3: `/private/tmp/plainsong-ios-c0-mac-attempt3/run.log`; full test/build PASS. xcresult: `Results.xcresult` in that directory. Mac performance uses CI timing classification and four opt-in skips; no idle/device performance acceptance.
- Portable/restored-positive checks: `/private/tmp/plainsong-ios-c0-portable.log`; SyntaxKit 1, WorkspaceCore 1, Core contract 2 and architecture 5 pass.
- Preliminary iOS compile: `/private/tmp/plainsong-ios-c0/2144c46c888360c84a42fef79e676e60b518048b-build.DBI9qx/build.log`; PASS before final freeze refinements.
- iOS freeze compile attempt 1: `...-build.fmLnQo/build.log`; private StoreDouble missed the added state accessor; compile fails with the exact conformance diagnostic, then the private consumer was completed.
- iOS freeze compile attempt 2: `...-build.glJZZ8/build.log`; PASS, both simulator architectures and all test products. `preview-resources.json` verifies all bundled files. These are precommit working-tree builds; publication receipt identifies the matching frozen sources and a subsequent clean-head build separately.
- Pinned lint: `/private/tmp/plainsong-ios-c0-lint-receipt.log`; SwiftFormat 0.62.1, SwiftLint zero serious violations. First sandbox lint failed its cache write after reporting zero serious violations; outside-sandbox rerun succeeds.

## Negative mutations

`/private/tmp/plainsong-ios-c0-negative-probes/results.json` and separate logs retain:

1. Make IOSDocumentRevision equality ignore document identity → `testSameVersionInDifferentOpenInstancesDoesNotAuthorizeTheSameRevision` fails `XCTAssertNotEqual` (exit 1).
2. Replace baseline acknowledgement with `markSaved(text:captured.text,url:nil)` → `testAcknowledgingAnOlderSavedCaptureRetainsNewerLiveSource` fails live-source/version assertions (exit 1).
3. Remove iOS `product: PreviewKitContracts` → `testIOSScaffoldDoesNotLinkMacOnlyProviders` fails isolation assertion (exit 1).

Every mutated file is restored in a finally block under the shared lock; restored-positive checks pass. This validates the contract/architecture checks, not an unimplemented native writer or provider. No negative mutation is committed.

## Open evidence

Exact-head hosted results belong to the created PR. iOS execution/runtime, M0 actual device IME/Undo/Files/background/install, provider integration, final IPA/accessibility/performance and Claude review remain OPEN. No fake successful provider is wired to production.
