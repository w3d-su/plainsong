# Keep iOS production composition unavailable and admit only one document writer

Phase A records live heads for lanes 06 (#172 `142e07d`), 07 (#173 `4607874`), 11 (#171 merged, #174 `767c0cf`), and 12 (tooling already on PR #164 head `fdbcd44`; the October 8 IPA is not that head). Frozen IOS-C0-v1 bytes still match tag `642cb21`. `IOSProductionComposition.c0` keeps every capability nil. `IOSOpenDocumentAdmission` refuses a second writer until the active ticket ends and does not compare URLs, inodes, or document identifiers; the app entry does not call it. Lane 06's `makeProduction` stays unwired. The unmerged preview reader publishes the logical grant URL, not the internal proved URL. `AcceptanceDebugSeam` stays hard-disabled. M0, real bundle ready, current-head IPA, and product acceptance stay open. Alternatives rejected: injecting the lane 06 factory behind a DEBUG flag, deduping nil provider identities by path, retargeting lane PRs, or treating split component logs as a 29-case product pass.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
