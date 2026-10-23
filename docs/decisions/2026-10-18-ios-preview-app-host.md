# Validate the complete iOS PreviewKit suite in a dedicated real app host

Lane 12's `IOSPreview` scheme uses a minimal SwiftUI app with no package dependencies and links PreviewKit/MarkdownCore once in its unit-test bundle. `make ios-preview` requires a built Mach-O app-hosted unit-test image, all original 94 named cases, no skips, resource parity, and source-bound required manifests. Lane 07 verifies the first controller's production-default app-bundled index and retains the original DOM assertions and 8-second readiness / 2-second JavaScript limits; offline export navigation failures throw before JavaScript and clean up immediately. A production-app-host comparison emitted duplicate Yams class warnings and an interrupted run; these do not prove the historical readiness or memory-spike cause. Full dedicated-host execution remains a separately sealed candidate gate. Alternatives rejected: enabling production providers to obtain a test host, warming a second controller, using a library-only/hostless result as app-host acceptance, or dropping the original failing cases.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
