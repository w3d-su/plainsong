# Export PR F Phase B — owner smoke and test entry points

All owner-only boxes below remain unchecked. Automated destination seams run in the app
container; they do not prove a real Powerbox leaf grant. Record date, macOS version,
Debug/Release build, exact `ExportArtifactWriteOutcome`, and any remaining paths under E6/E7
in `docs/export-gates.md` when the owner actually runs a case.

## Owner smoke (real Mac, real NSSavePanel, sandboxed Debug or Release)

- [ ] Desktop and Documents: create a new HTML file and overwrite one in each folder.
  No “(A Document Being Saved By …)” folder or other entry appears.
- [ ] Home-folder root: export `~/x.html`; exercise D5 containment rule (b).
- [ ] iCloud Drive: create and overwrite, overwrite an evicted file, and check whether
  the UI remains responsive during file materialization and coordination.
- [ ] Accented folder made with Terminal `mkdir café`: create and overwrite. On
  `destinationAlias`, record the exact panel URL and stop for the owner; do not relax D5.
- [ ] External APFS: a subfolder and the volume root; record staging location, same-device
  refusal, and any `.TemporaryItems` reported as indeterminate. exFAT/FAT32/HFS+ should
  refuse early as `unsupportedVolumeSemantics`.
- [ ] Modes: new file is `0644` with default umask; overwrite `0640` and `0755` while
  retaining their mode; a `0200` file refuses as `destinationUnreadable`.
- [ ] Single-file mode and a folder inside the open workspace: create and overwrite;
  test panel Cancel and progress Cancel; source, selection, scroll, dirty baseline,
  document URL, recents, tree, and recovery state remain unchanged.
- [ ] Indeterminate feedback: read the displaced-original and unknown-residue notices
  using the DEBUG preview below. Confirm every reported path, urgent recovery wording,
  accessible labels, and the real outcome's Reveal in Finder action. Never stage a real
  failure on user data.

Keyboard-only menu/panel/cancel/notice navigation and VoiceOver remain owner work. The
automated label tests do not close that acceptance. No PDF/Print owner case is part of F.

## Correctness entry points

Run from `/Users/davis._.su/Documents/plainsong-export-html-command`:

```sh
Scripts/run-export-html-hosted-tests.sh
swift test --package-path Packages/PreviewKit
swift test --package-path Packages/WorkspaceKit
Scripts/check-export-sandbox-root.sh
PATH=/private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/swiftformat-0.62.1:$PATH make lint
lockf -k /private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/plainsong-xcodebuild-test.lock make build
```

The hosted-test script starts a test-only loopback recorder outside the sandboxed app,
then passes its port through `TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT`. The recorder
refuses every remote request. Product entitlements stay client-only; no server entitlement
is added. `ExportHTMLOfflineTests` skips without this recorder in an ordinary broad run;
the script runs it with both the zero-request assertion and a positive live-preview control.

## Safe DEBUG feedback preview

Build with a known output directory under the shared lock:

```sh
lockf -k /private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/plainsong-xcodebuild-test.lock xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug -derivedDataPath /private/tmp/plainsong-export-f-owner build
PLAINSONG_EXPORT_FEEDBACK_SMOKE=displaced-original /private/tmp/plainsong-export-f-owner/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong
PLAINSONG_EXPORT_FEEDBACK_SMOKE=unknown /private/tmp/plainsong-export-f-owner/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong
```

Quit the first preview before launching the second. The banner starts with “Preview Only”
and “no files were written or moved”; the paths are fictional. It creates no file or
recovery record and offers no misleading Finder action for a nonexistent original.
`testIndeterminateStatesAndEveryResidueReportRecoveryPathsWithoutClaimingSuccess` asserts
the real notice's Reveal target. Check the owner box only after reading both previews.

## E9, last and only on an idle machine

```sh
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh Release
```

The script acquires the shared lock before checking 1-minute load and refuses a run above
1.0 (exit 75, “pending idle-machine run”). This is a conservative idle check, not an export
budget. It retains a `.xcresult` and `run.log` under the printed evidence directory.
Ordinary tests skip all three probes unless `PLAINSONG_RUN_EXPORT_E9=1` reaches the runner.

- `ExportHTMLPerformanceTests.testProductionOffscreenExportTimeAndHostMemory`: three
  full product-command samples per `large-1mb.md` and `export-f-heavy.md`, plus 24 bounded
  raster paths; elapsed time includes snapshot, policy compilation, render, D2, and writer.
  A 5 ms sampler reports peak sampled host RSS, not an exact OS high-water mark or WebKit
  helper-process memory.
- `ExportHTMLPerformanceTests.testSixtyFourMiBWriterMainActorTime`: three synchronous
  `writeExportArtifact` calls at 64 MiB, with byte allocation outside the timed interval.
- `AppBackedEditorPerformanceTests.testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget`:
  native input and the scheduled public-view update while the offscreen path is active;
  the edit correctly fences the captured export. It checks the existing 16 ms budget and
  is synthetic AppKit evidence, not physical-input or compositor proof.

The iCloud evicted-leaf/materialization and coordination wait must be measured by the
owner in the real sandboxed panel flow. No test manufactures an iCloud account. If the
writer stalls the UI noticeably, stop and propose an E2-contract review; do not move it
off-main in this PR. No export-specific time or memory budget is frozen.
