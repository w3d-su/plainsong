# M0 simulator execution and owner test kit — 2026-10-22

Source: `e20162e5c2402800e84cf1f68ae4787535228c50` (clean), the reviewed #188 integration head.
This follow-up changes documentation/evidence only. All 17 prototype source/input
file hashes in `prototype-source.json` remain equal to the executed and built tree.
No provider, production App, shared package, contract, build entry or test is changed.

## Executed evidence

| Scope | Result |
|---|---|
| iPhone 17, iOS 27.0 simulator | 17 Passed, 0 Failed, 0 Skipped |
| iPad Pro 11-inch (M5), iPadOS 27.0 simulator | 17 Passed, 0 Failed, 0 Skipped |
| Foundation core | 10 Passed |
| Deliberate old-save and canonical-Unicode defects | Both detected at their original named invariant |
| Release unsigned IPA | IOS platform, arm64, minimum 26.0, device families 1+2, no signature/profile, ZIP intact |
| Physical iPhone/iPad, iOS/iPadOS 26, real IME/File Provider/signing | OPEN, not executed |

Each simulator execution has a complete xcresult. Its enabled generated scheme,
Mach-O MH_EXECUTE app host, MH_BUNDLE XCTest image and actual named cases were
verified. `required-hosted-tests.txt` is derived from the three captured test source
files; all 17 names must pass with no skips. `prototype-source.json` binds those
source files by digest. Six clean per-attempt manifests agree on all 17 input hashes
before/after execution. Original logs, results, source copies, host applications,
mutation sources and the evidence collector are retained with the local delivery.

Xcode: 27.0 (27A5194q); SDK/runtime: 27.0; deployment target: 26.0.
The compiler/runtime versions do not establish minimum-OS or physical-device behavior.
Scene configuration and appearance-transition warnings occurred in hosted execution;
all assertions passed. Their causes are not established or treated as device acceptance.

## Reproduction

At the recorded commit, use the existing prototype public entry:

```sh
Prototypes/iOSM0/Scripts/run.sh inventory
Prototypes/iOSM0/Scripts/run.sh test <available-iPhone-simulator-UDID>
Prototypes/iOSM0/Scripts/run.sh test <available-iPad-simulator-UDID>
Prototypes/iOSM0/Scripts/run.sh core
Prototypes/iOSM0/Scripts/run.sh mutation
Prototypes/iOSM0/Scripts/run.sh ipa
```

These entry points acquire the canonical shared Xcode lock themselves. Exit75 is
lock admission, not a product failure. Do not wrap them in another holder of it.
Use private local simulator identifiers; never commit device inventory or raw results.
Every test run must retain a complete `Tests.xcresult`, manifest and original log.
For named-result validation from the repository root:

```sh
xcrun xcresulttool get test-results tests --path <attempt>/Tests.xcresult --format json > <private-output>/tests.json
python3 Scripts/ios/ios-test-results.py <private-output>/tests.json \
  --required docs/ios/evidence/m0/runtime-20261022/required-hosted-tests.txt \
  --report <private-output>/gate.json --names <private-output>/names.txt --no-skips
```

Before using this manifest on another checkout, verify all three `Tests/*.swift`
SHA-256 values against the recorded `prototype-source.json`. Require exactly17
passed names, not just an exit0, a build-for-testing result or a total without names.
Run result parsing under the canonical lock after the test runner releases it.

## Delivered binary

`PlainsongIOSM0-unsigned.ipa`

- SHA-256: `3a7ec6b11151a79a4279680d0152fd2bc1765652255605674ec129e0b708adcf`
- Fixture SHA-256: `38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144`
- Binary/source receipt: `build-receipt.json`.
- Full source digest set: `prototype-source.json`.

The local owner kit includes the IPA, checksums, public fixture, receipts, Chinese
quick start, installation notes, full manual checklist and ten OPEN result forms
(one per gate/device family). The binary is delivered as a task artifact; it is
not committed to Git or published as a release. See [owner installation](owner-install.md).

## Acceptance boundary

All five owner gates remain OPEN: M0-IME, M0-Presentation, M0-Files, M0-Save,
M0-Install. Programmatic marked text and app-private UIDocument tests do not prove
real Chinese candidates, Files/iCloud grants/downloads/offline/read-only/conflicts,
background termination, physical iPhone/iPad or owner signing/install behavior.
`production_composition_allowed` remains false. This is the M0 prototype, not a
composed Plainsong iOS v1 or a release acceptance receipt.

The 2026-10-08 results remain historical evidence. This packet supersedes their
simulator-not-executed row only; it does not close any owner gate. Claude review,
maintainer merge and any current-head CI remain separate.
