# M0 canonical check output — 2026-10-26

Implementation: `e572d16f960233f525a2d8c60b81e2e48df05941`. Evidence publication changes no prototype
inputs. The exact hashes and all 29 named hosted cases are in [runs.json](runs.json).

`20261026T111549Z-core-22ADCFD9`

```text
PASS oneWriter
PASS capturedAcknowledgement
PASS oldSaveLeavesNewRevisionDirty
PASS staleAcknowledgementRefused
PASS failedSavePreservesBaseline
PASS conflictRefusesSave
PASS unavailableRefusesSave
PASS unicodeBytesDefineDirty
PASS recoveryExactReadback
PASS recoveryFailureReported
10 checks passed (host Foundation only; no UIKit/device claim)
```

`20261026T111552Z-mutation-82DCE1F8`

```text
PASS: negative mutation detected at oldSaveLeavesNewRevisionDirty
PASS: negative mutation detected at unicodeBytesDefineDirty
```

`20261026T111511Z-test-3BF8B857`

```text
Executed 29 tests, with 0 failures (0 unexpected)
xcresult: 29 total, 29 passed, 0 failed, 0 skipped
All 29 source-declared test names matched the completed cases
** TEST SUCCEEDED **
runner exit 0
```

`20261026T111540Z-ipa-58BAE3F8`

```text
** BUILD SUCCEEDED **
IPA SHA-256: c51e3babc35f472f8303496d0af43b5e8ef645730a5dfab2c4f0145e029ca52e
Fixture SHA-256: 38b1b6a80749a22baa8cede8adf5af4ee598181ca4690dc4b7d64b6a850c5144
Fixture member: Payload/PlainsongIOSM0.app/m0.md
arm64 / iOS 26 minimum / families 1,2 / unsigned / owner install OPEN
```

The first failed 28-case run and the later 28-case pass remain source-specific
in the local attempt records. Historical 2026-10-08 output is preserved in
[historical-20261008-final-check-output.md](historical-20261008-final-check-output.md).
No physical-device, signing, performance or composed-app gate is closed.
