# M0 current review result — owner gates OPEN

The canonical implementation for PR #156 is `e572d16f960233f525a2d8c60b81e2e48df05941`. This receipt
supersedes the 2026-10-08 entrypoints and the earlier source-specific
[2026-10-26 review run](review-20261026.md). The publication commit changes
evidence only; every prototype input captured by the final runs matches this
implementation. [runs.json](runs.json) records all input hashes and named cases.

The current unsigned IPA is
`Prototypes/iOSM0/Artifacts/20261026T111540Z-ipa-58BAE3F8/PlainsongIOSM0-unsigned.ipa`.
IPA SHA-256: `c51e3babc35f472f8303496d0af43b5e8ef645730a5dfab2c4f0145e029ca52e`.
Fixture member: `Payload/PlainsongIOSM0.app/m0.md`.
Fixture SHA-256: `38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144` (243 bytes).
[ipa-receipt.json](ipa-receipt.json) binds those values to the implementation.
Use this receipt when selecting an artifact for owner re-signing; the older IPA
receipts describe different sources and must not select the current install kit.

| Validation on the canonical implementation | Result |
|---|---|
| Full app-hosted simulator XCTest | 29 passed, 0 failed, 0 skipped; all 29 names verified |
| Background assertion regressions | 5 passed: active N/N+1, expiration, refusal, no writer, recovery failure |
| Foundation save/Unicode/recovery checks | 10 passed |
| Old-save and Unicode negative mutations | Both detected at the intended invariant |
| Fixture packager negative guards | 3 passed |
| Release unsigned IPA | arm64; minimum iOS 26; iPhone/iPad; no signature/profile; ZIP fixture bytes verified |
| Pinned SwiftFormat 0.62.1, shell/Python syntax, JSON and diff checks | Passed |

All native commands used `/private/tmp/plainsong-xcodebuild-test.lock`. The final
public runners completed normally. Complete passing and failing logs, manifests
and xcresults remain under this worktree's ignored `Prototypes/iOSM0/Artifacts/`.
[final-check-output.md](final-check-output.md) gives the selected attempts.

The first new run on `0981b6b` executed 28 cases with one test-cleanup failure:
all background-lifetime assertions passed, but the deliberately conflicted
public fixture retained its UIKit unsaved change count during discard. The
test now explicitly clears that count only after verifying recovery and the
untouched original file. Its complete failed result is retained. `135cde3`
then passed 28/28. A final source review added the recovery-failure/active-write
regression, giving the current 29/29 result. Existing replacement-close Swift 6
mode warnings and the weak-variable warning remain visible in the retained
Swift 5.10 build logs; no current SDK/platform root cause is claimed.

The original 2026-10-08 files are preserved byte-for-byte as
[historical results](historical-20261008-results.md),
[historical runs](historical-20261008-runs.json),
[historical IPA receipt](historical-20261008-ipa-receipt.json), and
[historical final output](historical-20261008-final-check-output.md).
Their implementation `a12de450`, zero executed hosted tests and IPA `d0950224`
describe that historical source only. The older 24-case/`1db4e86c` review receipt
similarly describes `2e7d6ec`; neither is the current receipt.

All five owner gates remain **OPEN**: real Chinese candidate/Undo behavior,
presentation/performance on physical iPhone/iPad, Files/iCloud recent scope
restoration and provider behavior, background termination/recovery, and owner
signing/install. Simulator tests exercise injected background-token accounting;
they do not prove iOS suspension timing. Default bookmark data and explicit
start/stop scope pairing keep the restoration probe testable; success on a real
provider remains unverified. iOS 26 runtime, accessibility and performance are
unmeasured. No production provider or composed-app acceptance is introduced.
Use the [owner checklist](manual-checklist.md) and keep its results separate.
