# Lane 05 document lifecycle review fixes

Review branch: `codex/ios-storage-review-fixes`; implementation base: `b82d0c27e69ebe9260a1c71a0a4deb8a2cceec6b`. Frozen interface: IOS-C0-v1. This batch owns document internals, document tests, and this lane's evidence. Lane 06 providers and lane 13 production composition remain outside this batch.

## Resulting behavior

An external-change notice immediately blocks original-file saves, including previously queued saves. It drains an already-issued UIDocument save before reading the provider's current bytes. Self-write notices clear the temporary barrier and resume autosave for a still-dirty newer source. A failed or undecodable external read retains the barrier and persists dirty recovery before reporting unavailable. A proposed reload remains fenced through deferred reconciliation; refusal never resumes overwriting unknown external content. Clean newer revisions after edit/Undo trigger a fresh observation rather than leaving a permanent temporary barrier.

Close is one shared lifecycle operation. It suspends save admission, drains the writer, and compares the live revision again after the asynchronous provider close. A newer source yields retained recovery and a reopened provider, keeping the original lease alive. Source text, revision, and editor Undo are never rewritten by close. Failed recovery leaves the draft retained.

Replacing a resource with a newer access generation retains its registry slot while the old writer and existing external reads drain, dirty recovery becomes durable, and the old provider closes. It captures edits received during drain or close before releasing the old lease. Recovery or close failure refuses the replacement and keeps the old draft. Older generations cannot replace the current resource. Retirement does not admit new external reads after its reader drain; a presenter notice during provider close cannot outlive the retiring lease.

Successful save acknowledgement still uses `rebaseSavedText(to:)` exclusively. It updates the saved baseline for that immutable operation, never live source or the newer source's revision. In-flight completion can acknowledge its old entry until retirement finishes; replay after replacement cannot revise the new entry.

## Current verification status (2026-10-13)

The final 43-case source is ready for review. Both current generic build attempts received canonical-lock admission exit 75, so neither compiled nor executed tests. Native simulator discovery also failed in a separate team lane; this lane did not bypass the lock or replace native execution with a portable stub. The five failing guard probes and restored module execution remain pending. The earlier 41-case candidate passed on 2026-10-09; its retained inputs are separate from the final-source fingerprint.

## Executable verification

The structured review receipt and named-test results are recorded separately from the original 31-case delivery in `review-verification.json`. Each negative probe changes one guard in a complete temporary package snapshot, runs one named test, restores the exact bytes, and compares the entire source/test fingerprint. Build failures, lock-admission exit 75, zero tests, or skipped tests do not count as a killed probe.

Reproduce from the review source checkout with an installed simulator (the output directory must be test-owned):

```sh
python3 docs/ios/evidence/lane-05/run-review-negative-probes.py \
  --source "$PWD" \
  --output /private/tmp/plainsong-storage-review-reproduce \
  --device A24A1CB9-2861-4AA4-A79F-E53F768950D8 \
  --expected-count 43
```

The runner copies `MarkdownCore`, `WorkspaceCore`, `PreviewKit`, and `WorkspaceKitIOS`, excluding generated build folders, and never mutates the source checkout. Every Xcode execution uses the canonical lock with 45-second admission. Five guard probes cover pending external observation, post-close revision reconciliation, writer drain before retirement, read admission during retirement, and recovery after retirement close. The final restored run executes the complete 43-case WorkspaceKitIOS module. Xcode's verbose failure diagnostics are disabled for deliberate assertion failures; test failures and xcresults remain retained, with a 60-second per-test deadline and a 600-second operation deadline. A stalled operation is infrastructure failure, never a killed guard probe; cleanup signals only the private process group spawned for that operation.

## Evidence boundaries

- Simulator document tests and deterministic I/O doubles verify these lifecycle contracts. They do not verify real Files/iCloud authorization, cloud conflicts, or physical IME/Undo behavior.
- All 13 frozen contract-file hashes must match the recorded IOS-C0-v1 manifest; no public contract or package manifest is changed.
- Pinned SwiftFormat 0.62.1 checks document sources/tests. Mac `make test`, exact-head hosted CI, signed installation, physical background termination/relaunch, and typing-latency measurements are not claimed by this lane.
- The existing owner-only gates in `device-acceptance.md` remain open. No IPA or working production composition is produced here.

Suggested central Decision Log addition: external observations and lifecycle transitions temporarily fence writes; replacement admission waits for writer/read drain, durable recovery, and lease-safe provider retirement. Publishing a new entry immediately or trusting the result of an earlier close was rejected because either can release a newer draft or overlap provider ownership. Root owns the architecture/Decision Log update.
