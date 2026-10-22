# Require a passing preview prerequisite before iOS composition

Review of `c09e712` verified that per-admission issuance fixes stale same-document release; all 660 retained native-run inputs match that head and all 13 frozen files match IOS-C0-v1. The October 16 phrase "recorded lane 07 result" incorrectly allowed FAIL to satisfy a wiring prerequisite. Phase B now requires the first real-bundle controller and the full required PreviewKit suite to pass, with the original assertions and 8-second readiness / 2-second JavaScript limits in a real app-hosted test process. Lane 12 owns host/scheme scaffolding independently of production composition. M0 remains a start condition; composed-head product acceptance and IPA remain final acceptance. Alternatives rejected: accepting a recorded failure, warming a second controller, or restoring the circular requirement for a composed binary before wiring starts.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
