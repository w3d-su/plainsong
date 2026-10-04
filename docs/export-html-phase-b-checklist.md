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
mkdir -p "$(dirname "${PLAINSONG_XCODEBUILD_LOCK:-${TMPDIR:-/tmp}/plainsong-xcodebuild-test.lock}")"
Scripts/run-export-html-hosted-tests.sh
swift test --package-path Packages/PreviewKit
swift test --package-path Packages/WorkspaceKit
Scripts/check-export-sandbox-root.sh
make lint  # SwiftFormat 0.62.1, the CI pin, first on PATH
lockf -k "${PLAINSONG_XCODEBUILD_LOCK:-${TMPDIR:-/tmp}/plainsong-xcodebuild-test.lock}" make build
```

The hosted-test script starts a test-only loopback recorder outside the sandboxed app,
then passes its port through `TEST_RUNNER_PLAINSONG_EXPORT_TEST_PROXY_PORT`. The recorder
refuses every remote request. Product entitlements stay client-only; no server entitlement
is added. `ExportHTMLOfflineTests` skips without this recorder in an ordinary broad run;
the script runs it with both the zero-request assertion and a positive live-preview control.

## Safe DEBUG feedback preview

Build with a known output directory under the shared lock (create its parent directory first):

```sh
lockf -k "${PLAINSONG_XCODEBUILD_LOCK:-${TMPDIR:-/tmp}/plainsong-xcodebuild-test.lock}" xcodebuild -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug -derivedDataPath /private/tmp/plainsong-export-f-owner build
PLAINSONG_EXPORT_FEEDBACK_SMOKE=displaced-original /private/tmp/plainsong-export-f-owner/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong
PLAINSONG_EXPORT_FEEDBACK_SMOKE=unknown /private/tmp/plainsong-export-f-owner/Build/Products/Debug/Plainsong.app/Contents/MacOS/Plainsong
```

Quit the first preview before launching the second. The banner starts with “Preview Only”
and “no files were written or moved”; the paths are fictional. It creates no file or
recovery record and offers no misleading Finder action for a nonexistent original.
`testIndeterminateStatesAndEveryResidueReportRecoveryPathsWithoutClaimingSuccess` asserts
the real notice's Reveal target. Check the owner box only after reading both previews.

## E9, last on a quiet machine; observed under recorded load

```sh
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh Release
```

The script acquires the shared lock non-blockingly, with a five-minute bounded wait.
Inside the lock it refuses any other `xcodebuild`, `swift-build`, `swift-frontend`, `clang`
or `ld`, and load above `PLAINSONG_MAX_LOAD` (default 6). These are contention guards,
not idle acceptance. Pause other agents, close heavy apps, keep the Mac on power and
leave it alone. Start/end load, top five CPU processes and product SHA are retained
with the `.xcresult` and `run.log`. The dedicated `PerformanceTests` scheme builds only the E9 test bundle and its
app/package dependencies, excluding unrelated Debug-only AppTests and UITests.
Each configuration builds once, then uses
`test-without-building`; after compilation admission is checked again.
Release passes `ENABLE_TESTABILITY=YES` for the existing `@testable` seams while
retaining the scheme's Release optimization. These are testable Release measurements,
not retail-binary measurements; testability can affect optimization and timing.
Interleave at least five Debug and five Release runs, with `--plain` typing batches
before each export batch. Use ten pairs per configuration for the common paired
regression method: per-pair differences, 10,000-resample bootstrap 95% CI, signal only
with CI above +0.5 ms and candidate worse in at least 80% of pairs. Report sample
fractions above 16 ms for both modes without claiming an absolute budget verdict.

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
export PLAINSONG_MAX_LOAD=6
Scripts/run-export-html-e9.sh --build-only Debug
Scripts/run-export-html-e9.sh --build-only Release
Scripts/run-export-html-e9.sh --plain Debug
Scripts/run-export-html-e9.sh Debug
Scripts/run-export-html-e9.sh --plain Release
Scripts/run-export-html-e9.sh Release
# Repeat the four measurement calls ten times; no other builds/tests may run.
# Or let the paired runner build once and perform the full interleaving:
/usr/bin/python3 Scripts/run-export-html-e9-paired.py
```

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

Correctness-only E9 smoke: `Scripts/run-export-html-e9.sh --smoke Debug`. It executes
one sample per fixture and the 64 MiB writer, and exercises active-export typing without
budget assertions or reporting timing/RSS as evidence. It holds the same lock but skips
the load ceiling; other-build exclusion stays active. Smoke reports no timing evidence.
Formal results are labeled observed under recorded load; idle-absolute acceptance stays open.
