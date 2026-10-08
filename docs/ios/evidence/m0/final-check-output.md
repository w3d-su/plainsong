# M0 final check output

Implementation: `a12de4502941aed964dee42533bf39d775c2b6a9`.

Host-only checks and deliberate negative probes. No UIKit test or owner device PASS.

`20261008T100118Z-core-FCC015BD`

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

`20261008T100120Z-mutation-C5CD7EC3`

```text
FAIL oldSaveLeavesNewRevisionDirty
PASS oneWriter
PASS capturedAcknowledgement
PASS: negative mutation detected at oldSaveLeavesNewRevisionDirty
FAIL unicodeBytesDefineDirty
PASS oneWriter
PASS capturedAcknowledgement
PASS oldSaveLeavesNewRevisionDirty
PASS staleAcknowledgementRefused
PASS failedSavePreservesBaseline
PASS conflictRefusesSave
PASS unavailableRefusesSave
PASS: negative mutation detected at unicodeBytesDefineDirty
```

`20261008T100122Z-build-tests-8887580A`

```text
** TEST BUILD SUCCEEDED **
COMPILED ONLY: hosted simulator tests not executed.
```

`20261008T100133Z-ipa-1B1C5DD3`

```text
** BUILD SUCCEEDED **
```

