# iOS build run evidence index — 2026-10-08

（`docs/ios/evidence/build/` 被 repo `.gitignore` 的裸 `build/` pattern 攔截，且
`.gitignore` 不在本 lane 可改清單——實跑索引依 lane-owned evidence 慣例落於此檔。
若 13/maintainer 要啟用 `docs/ios/evidence/build/`，在 `.gitignore` 加
`!docs/ios/evidence/build/` 即可平移。）

Binaries live under `/private/tmp/plainsong-ios-release/` (not committed — indexes and
checksums only, per lane-12 handoff). All runs in this worktree at head
`39e522e27d1e3fb623e4a3caa298e136d703d50e` (`source_dirty: true`), C0 base
`642cb212703220409874a2741c5adbfb8c80fe8a` (`ios-c0-v1`), contract `IOS-C0-v1`,
Xcode 27.0 (`27A5194q`), iphoneos/iphonesimulator SDK 27.0, deployment target iOS 26.0.

## Runs (all exit 0)

| Gate | Command | Result | Evidence |
|---|---|---|---|
| Build (sim) | `make ios-build` | **BUILD SUCCEEDED** | `evidence/39e522e27d1e-build-20261008-202130-55773/` — build.json, build.log, macho-platform.txt, archs.txt, signing-state.txt |
| Test (sim) | `make ios-test` | **TEST EXECUTE SUCCEEDED**, 12/12 named tests | `evidence/39e522e27d1e-test-20261008-202344-58129/` — test.json, named-tests.txt, Results.xcresult, resources.json; device iPhone 17 Pro `59CB04BD-26CC-4841-8D06-E75A2EDEBC66` (iOS 27.0 runtime) |
| Archive (device) | `make ios-archive` | **ARCHIVE SUCCEEDED** | `PlainsongIOS-39e522e27d1e.xcarchive` + `-meta/` (head stamp, archive.json, signing.txt, resources.json, macho-platform.txt, archs.txt) |
| IPA (unsigned) | `make ios-ipa` | packaged + verified | `PlainsongIOS-39e522e27d1e.ipa` (2,460,581 B) + `ipa-meta-39e522e27d1e/` |

## Checksums

| Artifact | SHA-256 |
|---|---|
| `PlainsongIOS-39e522e27d1e.ipa` | `dbb86a98242c7e04bb5b4bb57482a61c27919779d06a8fb9063294da0dff473a` |
| `PlainsongIOS-39e522e27d1e.xcarchive` (content manifest digest) | `de6ba90b89ec21edaead3491814b3565ffc1c62619011ae333ee1711874e61cc` |
| `PlainsongIOS.app/PlainsongIOS` executable | `bb48dcb5edb6459c894df21b37a413057c55ea4ebb010ba5da37dd943e0ba5b9` |

Archive digest = SHA-256 of the sorted per-file `shasum -a 256` manifest inside the
bundle (see `run-ios-ipa.sh`); sidecar `*.xcarchive.sha256` next to the archive.
Zip output is not bit-reproducible — the sidecar is regenerated with each `ios-ipa` run
and always matches the artifact it ships with.

## IPA structural verification (post-unzip)

- `Payload/` contains **only** `PlainsongIOS.app`; no stray files.
- Mach-O (`vtool`): `platform IOS`, `minos 26.0`, `sdk 27.0`; `lipo`: `arm64`.
- `codesign -dv`: *"code object is not signed at all"*; the app embeds zero
  `.framework`/`.appex`/`.xctest` (pure static-package app → no nested bundles, the
  report records the app itself as `unsigned`); zero `.mobileprovision`/
  `_CodeSignature`/`.p12`.
- `preview/` bundle present (`index.html`, `bundle.js`, `bundle.css`,
  `font-manifest.json`, `fonts/`) — shared committed preview dist.
- `Info.plist`: `CFBundleDocumentTypes` markdown/mdx + `LSSupportsOpeningDocumentsInPlace`,
  `MinimumOSVersion 26.0`, `UIApplicationSupportsMultipleScenes=false` (single scene),
  bundle id `app.plainsong.editor.ios`.

## Negative probes (local, expected non-zero)

| Probe | Expected | Observed |
|---|---|---|
| `PLAINSONG_XCODEBUILD_LOCK=/tmp/wrong.lock make ios-build` | exit 64 | exit 64 — "must be '/private/tmp/plainsong-xcodebuild-test.lock'" |
| `make ios-test IOS_DESTINATION='platform=iOS Simulator,id=0000…'` | exit 64 | exit 64 — prints available iOS 26+ simulator list |
| `IOS_ARCHIVE_PATH=<foreign-head>.xcarchive make ios-ipa` | exit 3 | exit 3 — "built for a different head … never repackage a previous round" |

## Mac regression (this lane changed shared `project.yml`/`Makefile`)

- `xcodegen generate` + `xcodebuild -list`: targets `Plainsong`, `PlainsongTests`,
  `PlainsongUITests`, `PerformanceTests` unchanged; added `PlainsongIOS`,
  `PlainsongIOSTests`; schemes include `PlainsongIOS` + iOS package schemes.
- `make build` (under shared lock): **BUILD SUCCEEDED**.
- `make -n test`: identical recipe expansion — same `PACKAGES` loop
  (`MarkdownCore EditorKit PreviewKit WorkspaceKit`), same f2 tooling tests; iOS-only
  packages are in `PACKAGES_PORTABLE_*` variables that `test` never references.
- `make lint`: **FAILED — pre-existing**, in product sources untouched by this lane
  (e.g. `WorkspaceKit/ExportArtifactWriter+Hooks.swift`, `EditorFindMatchWorker.swift`
  `redundantSendable`; 7/609 files, local swiftformat 0.61.1 vs CI pin 0.62.1).
  Recorded as data for 13/maintainer; lane scope cannot modify `Packages/**`.
- `git diff --check`: clean.

## Gate status

- **BUILD PASS** — local build/test/archive/IPA all exit 0 with structural evidence above.
- **INSTALL OPEN** — unsigned IPA is *not* installable and *not* device-validated;
  owner re-sign → install → launch → Files open/save remains a separate owner gate.
- Exact-head hosted CI: `ios.yml` is `workflow_dispatch`-only and committed — not yet
  triggered (no hosted run ID to report).
