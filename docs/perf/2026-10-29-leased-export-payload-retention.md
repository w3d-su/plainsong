# Leased export raster payload retention

- Date: 2026-10-29 (Asia/Taipei)
- Commit: uncommitted changes on `07521d1e61edb0eec9225ac0abdac0374955caa4`
- Environment: arm64 Mac, macOS 27.0 (26A428), Xcode 27.0 (27A5194q),
  Debug, app-hosted `IOSPreviewTests`, iPhone 17 Pro / iOS 27.0 Simulator.
- Fixture: eight distinct asset URLs; each reader return owns a separately allocated,
  valid 10 MiB PNG. `Data(bytesNoCopy:deallocator:)` tracks live reader allocations.
  The shared fixture template, base64 strings, and process RSS are outside this counter.
- Budget: D3 in `docs/export-gates.md` retains at most 32 MiB of distinct accepted
  raster payload, with one additional 10 MiB reader buffer allowed during this probe.
- Procedure: execute
  `IOSPreviewTests/ExportLeasedResourceResolverTests/testReaderPayloadRetentionStaysWithinBudgetWithOneReadAllowance`
  through the `IOSPreview` scheme on simulator
  `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, under
  `/private/tmp/plainsong-xcodebuild-test.lock`.

| Measurement | Before | After |
|---|---:|---:|
| Peak live raw reader payload | 83,886,080 bytes (80 MiB) | 10,485,760 bytes (10 MiB) |
| Probe allowance | 44,040,192 bytes (42 MiB) | 44,040,192 bytes (42 MiB) |
| Reader allocations | 8 | 8 |
| Embedded / omitted images | 3 / 5 | 3 / 5 |
| Result | FAIL | PASS |

The before run used the original resolver with the new allocation regression test.
Both runs and their result bundles are retained under
`/private/tmp/plainsong-leased-export-fix-20261029/`: `before.log`,
`before.xcresult`, `after-focused.log`, and `after-focused.xcresult`.
`ExportResourceResolver.before.swift` retains the original implementation.

The fix processes resources in document order against one shared raster budget,
releases raw reader bytes before the next read, and only base64-encodes an admitted
local image. Repeated images retain a decision and reference the first embedded
outcome. A rejected image does not consume budget or prevent a later smaller image
from fitting. The 10 MiB per-image, 32 MiB aggregate, and 64 MiB HTML limits are unchanged.

The focused app-hosted run passed all 15 resolver tests with no failures or skips.
The four new tests cover tracked payload retention, mixed authored/local ordering
with a later fitting image and repeated references, rejected raster bytes, and
cancellation during a provider read. They are required by
`Scripts/ios/required-preview-tests.txt`.

The subsequent full app-hosted `make ios-preview` on the same simulator executed
202 tests, passed 202, failed 0, and skipped 0 (exit 0). Its memory case again
reported `peakPayloadBytes=10485760`, `allowance=44040192`, and `reads=8`.
Source fingerprint
`6f6f57802c94aa1fb50c4c79ec007e3ce2d4c77db1e1f451e94f5b85f3487ce1` still matches
the dirty tree at HEAD `07521d1e61edb0eec9225ac0abdac0374955caa4`; the
documentation update is outside that native-input fingerprint. Evidence is
`/private/tmp/plainsong-leased-export-fix-20261029/full-preview/evidence/07521d1e61ed-preview-20261029-031615-24181/`
(`test.json`, `test-gate.json`, `test.log`, `Results.xcresult`) and
`/private/tmp/plainsong-leased-export-fix-20261029/full-preview-runner.log`.

This measures raw reader-buffer lifetime, not total host/WebKit RSS or device
jetsam behavior. It is local simulator evidence; minimum-iOS, physical-device,
physical-printing, and CI acceptance are separate.

Import note, 2026-11-15: this record was written with the fix on 2026-10-29 and left
out of #228. It is added unchanged above. The `/private/tmp` logs and result bundles
it names no longer exist; the regression test it names is on `main` and passed in the
2026-11-15 `make ios-preview` run recorded in `docs/ios/integration-ledger.md`.
