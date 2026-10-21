# Reconcile approved iOS extraction inventories and implement acceptance review fixes in isolated branches

The user requested parallel subagents after the 13-lane audit. The central dependency pin now reflects lane02 moving existing TreeSitter dependencies into SyntaxKit and lane03 adding WorkspaceCore to the Mac workspace adapter, preserving exact third-party versions and mutation bans. Review fixes retain frozen IOS-C0-v1 contracts and separate local module execution, exact-head CI, owner M0/device, and performance gates. Existing lane checkouts and PR bases are preserved; a new local aggregate is used for controlled regressions, not a maintainer merge. Alternatives: disabling the inventory test, granting implicit parent access, weakening assertions, or declaring skipped/zero-run tests complete were rejected.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
