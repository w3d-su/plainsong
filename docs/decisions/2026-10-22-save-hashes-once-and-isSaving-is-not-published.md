# A save hashes its text once, and `isSaving` is no longer published

`AppState.save(session:)` computed the SHA-256 of the saved text twice on the main thread
after a committed write (`WorkspaceSearchContentFingerprint(text:)` for the anchored binding
and `contentHash(_:)`, which is the same function, for `lastKnownDiskHashes`), and a third
time for an indeterminate write's context. It now computes one digest per save and passes it
to all three. The writer's own hashing of the prepared bytes, the temporary file and the
destination is part of its durability proof and is unchanged.

`isSaving` was `@Published` and set and cleared in the same synchronous call, so no view
could ever observe `true`, but each save published twice and re-rendered every `AppState`
observer twice. It is now a plain property that still guards `canSave`.

Deferred: moving the anchored write (with its `fsync`s) to a serialized background writer.
`save(session:)` arbitrates write fences, indeterminate-write reconciliation, external-change
prompts, missing-file state, image-asset authority rebinding and recovery records around the
write, all on the main actor; running the write off it needs a design for edits, workspace
switches and window closes that land while a write is in flight, which this change does not
attempt. If that lands, `isSaving` becomes observable and should be published again.

Alternatives: have the writer return the digest it computed (rejected for now: it hashes the
prepared `Data`, a different call site from the text, and changing the writer's result type
touches every caller of the anchored write API for a single SHA-256).
