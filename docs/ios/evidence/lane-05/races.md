# Lane 05 races and negative probes

All commands used the WorkspaceKitIOS package scheme, iPhone 17 Pro simulator `59CB04BD-26CC-4841-8D06-E75A2EDEBC66`, and `/private/tmp/plainsong-xcodebuild-test.lock`. The green run is `/tmp/plainsong-doc-io-test3.log` (31 tests, 0 failures).

## Races that passed on the restored tree

- `testBlockedSaveThenNewerEditKeepsLiveSourceDirtyUntilSecondSave`: block save(v1), edit to v2, release v1. Live text and version stay on v2, dirty, baseline v1. The following save of v2 is the one that becomes clean.
- `testStaleSaveCompletionCannotRewriteNewerSource`: replaying the older completion does not change live text, version, or dirty state.
- `testSerializedWriterNeverOverlapsProviderSaves`: peak in-flight provider saves is 1, and the written bytes end at the newer snapshot.
- `testAliasedOpensShareOneSessionAndOneWriter`: two opens with the same resource id share one session and one port.
- `testUnscopedUnicodeSpellingsDoNotShareAWriter`: NFC and NFD relative paths without a resource id are different entries.
- `testStaleGenerationSaveCannotReviseTheReplacement`: a save started on generation 1 cannot revise the generation 2 session.
- `testExternalReadDroppedAfterGenerationSessionOrEditChanges`: an edit during a blocked external read does not publish that read.
- `testStaleExternalReadCannotUpdateAReplacementRoot`: releasing the old read after a generation change leaves the replacement clean.
- `testDirtyConflictFencesWritesAndAutosaveDoesNotTouchTheOriginal`: after conflict, autosave and `save` perform no original-file write.
- `testBackgroundDeadlinePersistsRecoveryWithoutClaimingSave`: flush returns `.recovered` while the provider save is still parked. The draft is unchanged.
- `testCancelledSaveKeepsTheDraftAndRetryCanFinish`: cancelling the waiting task does not drop the draft. The provider completion still applies, and a later dirty save can finish.

## Negative probes

Each probe was applied to a copy of the restored sources, one named test was run, and the sources were compared back to the pre-probe bytes. `cmp` reported the restored files identical.

| Probe | Named test | Result |
|---|---|---|
| Replace `rebaseSavedText(to:)` with `markSaved(text:url:)` | `testBlockedSaveThenNewerEditKeepsLiveSourceDirtyUntilSecondSave` | Failed. Live text became `v1` instead of `v2 繁中 👩🏽‍💻`, version became 3 instead of 2, and `isDirty` was false. Log `/tmp/probe-markSaved.log` |
| Remove `await previous?.value` from `IOSDocumentWriteQueue.enqueue` | `testSerializedWriterNeverOverlapsProviderSaves` | Failed. The test process crashed in `XCTestExpectation.fulfill` (`freed pointer was not the last allocation`) because both saves entered the port and fulfilled the same expectation. Xcode listed this test as failing. Log `/tmp/probe-serialization.log` |
| `entryForAcknowledgement` returns the current registry entry with no generation check | `testStaleGenerationSaveCannotReviseTheReplacement` | Failed. `XCTAssertFalse(replacement.session.isDirty)` failed, so the old completion dirtied the replacement. Log `/tmp/probe-generation.log` |
| Publish `.conflict` and `recoveryPersisted` before `recovery.persist` | `testConflictEventRequiresDurableRecovery` | Failed. `XCTAssertFalse` on `recoveryPersisted` failed, so a conflict receipt was emitted before the failing write. Log `/tmp/probe-conflict.log` |
