# M0 Fixture / delay repair — 2026-10-22

The owner reported **iPhone 14 Pro, iOS 27**, with Fixture doing nothing and Delay
unclear. The delivered original IPA (`3a7ec6b11151a79a4279680d0152fd2bc1765652255605674ec129e0b708adcf`)
contains only Info.plist, PkgInfo and its executable; it has **no m0.md**.
The prototype's unsupported target-level `resources` property was ignored by
XcodeGen, and the missing-resource branch silently returned. The original 17 tests
used their own temporary documents and did not cover this button/resource path.
Those earlier test results remain historical evidence; they did not prove Fixture.

## Repair

The manifest now adds `Fixtures/m0.md` as a `sources` entry with `buildPhase: resources`.
Missing resources display an explicit status/error event. Packaging rejects missing,
symlinked or byte-mismatched bundled fixtures and verifies the actual ZIP member.
The receipt binds its member name, bytes and SHA-256 to the source fixture.

The Delay button shows `3秒：關/開` with persistent inline instructions and accessible
state. It still delays saves and syntax presentation by three seconds; typing remains
immediate. Controls scroll in compact layouts to preserve editor space. Toggling
only changes timing and labels; it does not present a modal or change input state.
Production packages, AppIOS, shared contracts and root build files are unchanged.

## Validation

Clean executed/built source: `806989d176f61f0825973fbd2eb9bee444a6d16b`. The later evidence commit changes only docs;
all prototype inputs remain byte-identical to `prototype-source.json`.

| Scope | Result |
|---|---|
| iPhone 17 / iOS 27.0 simulator | 20 passed, 0 failed, 0 skipped |
| iPad Pro 11-inch (M5) / iPadOS 27.0 simulator | 20 passed, 0 failed, 0 skipped |
| Existing cases | All 17 retained and passed on both families |
| New workflows | Actual Fixture UIButton → bundled bytes → editable app-private UIDocument; persistent/compact Delay UI and native marked-text preservation; actual delayed session/document writer N then N+1 |
| Foundation / two ledger mutations | 10 checks passed; both deliberate defects detected |
| Live-source writer mutation | Source23a4d727: 19 passed / only the new delayed-session case failed from wrong disk bytes; complete result retained and writer restored |
| Packaging negative controls | Missing, wrong-byte and symlink fixtures rejected before output creation |
| New Release IPA | arm64 / IOS, minimum26, families1+2, unsigned, ZIP intact; bundled m0.md matches original bytes |
| Physical retest / minimum OS / performance | OPEN; not established by simulator or build |

The first new-test build failed because throwing reads were used in nonthrowing save
callbacks. Both cancelled attempts are retained and excluded from runtime/negative
PASS claims. The corrected callback uses an optional read whose nil also fails the
expected-byte assertion. Final positives and the valid executed mutation are
separately identified in receipts; no assertions or time limits were removed.
A later wrong-writer attempt printed the expected assertion failures but disk
exhaustion prevented result finalization (no Info.plist / no exit code); it is
retained as an incomplete observation and excluded from negative-control PASS.
Only inactive compilation caches from this task were removed; sources, binaries,
logs and results were retained. The original writer was then restored and verified
byte-identical before the complete rerun.

Complete xcresults, original logs/manifests, source/overlay copies, host apps and
workflow screenshots are retained in the local task artifact.
A clean source23a4d727 run had 19 passed / one Fixture six-second readiness failure;
its exact cause remains unproven. The next commit added timeout-only state/Probe
attachments, preserving every assertion and the 6/12-second bounds. It did not
change the product, host or scheme. Earlier mutant runs passed Fixture. The final
clean per-family results are reported separately; they do not erase that timeout
or prove a specific cause/fix. Physical Fixture reliability still needs retesting.
The first iPad compact-layout proxy was 393x500; all controls fitted, so its
overflow assertion correctly failed. The proxy was reduced to393x390 to actually
exercise scrolling, with the same assertions and source/composition checks.
The writer negative control predates those diagnostics and layout-fixture changes; its source
SHA, complete input manifest and overlay are explicit, and its product source bytes
match the final positive source. It is historical executed mutation evidence, not
a claim that the changed diagnostic/layout harness was rerun with the mutation. Named tests are
validated against all four captured test source files, with no skips. Xcode27.0
(27A5194q), SDK/runtime27.0; minimum26 compile target is not26 runtime evidence.
The source-level mutation changes only the real document writer argument from the
immutable capture to live editor text; no synthetic provider or instrumentation is
substituted. Its baseline/overlay and input manifests are retained.

IPA SHA-256: `95b7882c2ec32c0f7a01f25b46bef8b25209bf6ad5bd98fdd6db52e37347ee96`. Fixture SHA-256: `38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144`.
The local owner kit contains the fixed IPA, fixture, checksums, Chinese quick start,
installation guide, receipts and ten OPEN physical-result forms. It is delivered
as a task artifact, not committed as a binary or published as a release.

## Reproduce

At the recorded source commit, use `Prototypes/iOSM0/Scripts/run.sh test <UDID>` once
per iPhone/iPad simulator, then `core`, `mutation` and `ipa`. These entries take the
canonical `/private/tmp/plainsong-xcodebuild-test.lock` themselves; do not nest it.
Exit75 means lock scheduling. Preserve every attempt and complete xcresult.
Copy this packet's source/test manifests outside the checkout before checking out
the older source commit. Verify every input digest, then use the repository's
`Scripts/ios/ios-test-results.py` with `required-hosted-tests.txt` and `--no-skips`
on xcresulttool's test-results JSON; require exactly20 passed names on each family.
The packaging negative controls and wrong-writer run are detailed in
`negative-controls.json`; their actual exit codes, named failure and restoration
hashes are recorded separately from the positive runs.

## Owner evidence boundary

`owner-observation.json` records the user's exact scope without inferring individual
IME, Files/iCloud or lifecycle steps. The installed binary digest and signing method
were not supplied. All five physical gates remain OPEN; new Fixture/Delay must be
retested. No iPad or iOS/iPadOS26 evidence was provided. Production composition
remains disconnected. CI, Claude review and maintainer merge remain separate gates.

Official configuration reference: [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md),
checked using Context7 library/docs on 2026-10-22. The docs describe resource files
as target sources with `buildPhase: resources`; the original target-level property
was not recognized. The CLI transcript is retained with local evidence.
