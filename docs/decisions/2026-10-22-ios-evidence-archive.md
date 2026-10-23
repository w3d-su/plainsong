# Preserve historical iOS evidence outside the current tree

PR #188 carried 301 evidence files (4,475,866 bytes), including repeated full
source inventories and raw diagnostic output. Keep the latest integration packet,
human receipts, current test inputs and owner checklists; move 228 historical
generated/replay files (3,573,439 bytes) out of the working tree.

The exact originals stay at `e20162e5c2402800e84cf1f68ae4787535228c50`, pinned by
`ios-phase-a-evidence-20261022`. The [archive index](../ios/evidence/README.md)
provides an exhaustive SHA-256 list and a restoration command. References to moved
files use the fixed commit, and historical local-path commands require that restored
tree. Preserve the archive tag after squash merge or branch deletion.

No product, test expectation, required-name manifest or parser baseline changes in
this cleanup. The latest native/input receipts keep their original hashes and
source-bound meaning. The owner M0/device/product gates remain open. Full clones may
still carry archived blobs; there is no history rewrite or claim of shrinking them.

Replacing full evidence with only summaries/checksums was rejected because a digest
cannot reconstruct the original bytes. Keeping every raw attempt in main was
rejected because it obscures the product diff and burdens each checkout. An expiring
CI artifact is insufficient as the sole archive.
