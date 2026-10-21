# Verify hard-link path policy using the same actual syscall observation and separate controlled outcomes

Initial iOS-review Mac CI38359852530 failed an unchanged ExportArtifactWriter test that assumed a preceding lookup guaranteed the next F_GETPATH spelling. The historical log did not retain actual bytes, so kernel/cache cause remains unconfirmed. Nil-default internal observation records the raw real reply before any explicitly test-only override; production still performs one fcntl and the unchanged byte-exact alias guard. Native tests assert against that same observed reply and its validity; deterministic matching and mismatch tests require exact identity, fail-closed publication, zero staging and unchanged originals. Removing the guard actually fails the named test; source hashes restore and final69 focused/362 package tests pass. Alternatives: weakening the writer gate, claiming cache causality from a green rerun, or relying on lookup order for deterministic kernel spelling were rejected.

Preserved from the iOS review branch during main integration. Status and head
references above describe the original decision date; current evidence is tracked in
[`docs/ios/integration-ledger.md`](../ios/integration-ledger.md).
