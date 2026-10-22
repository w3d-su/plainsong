# Lane 09 named tests

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Simulator target: `PlainsongIOSTests` on scheme `PlainsongIOS`. Private doubles: `PausableImageWriter`, `ImageEditorFake`. Barriers are `AsyncSignal`, not sleeps.

## IOSImageInsertionOrderingTests

- `testPersistenceAndValidateFinishBeforeTheSourceEdit`
- `testAcceptedInsertionUsesTheSavedRelativePath`
- `testUndoAndRedoKeepTheCommittedImage`
- `testRetainedCommitAfterAcceptIsStillInserted`
- `testCancelObservedInsideApplyStillCommits`

## IOSImageInsertionStaleTests

- `testSwitchingDocumentDuringStageRollsBack`
- `testSameVersionDifferentDocumentRollsBack`
- `testNativeEditDuringStageRollsBack`
- `testSelectionABARollsBack`
- `testAccessGenerationChangeDuringStageRollsBack`
- `testComposingDuringStageRollsBack`
- `testReadOnlyDuringStageRollsBack`
- `testLostFocusDuringStageRollsBack`
- `testBindingReplacementDuringStageRollsBack`
- `testMissingSnapshotDuringStageRollsBack`
- `testAccessGenerationChangeAfterValidateRollsBack`
- `testDestinationValidationFailureRollsBack`
- `testStagedWorkspaceReplacementRollsBack`
- `testStagedGenerationMismatchRollsBack`
- `testURLPrefixIsNotGrantAuthority`
- `testSingleFileGrantDoesNotSaveOrEdit`
- `testComposingOrUnfocusedCaptureDoesNotOpen`

## IOSImageInsertionTerminalTests

- `testCancelBeforeStageDoesNotCallWriter`
- `testCancelDuringStageRollsBackOnce`
- `testPickerDismissalDoesNotSaveOrEdit`
- `testTeardownDuringStageRollsBackOnce`
- `testDuplicateFinishImportStagesOnce`
- `testDuplicateInsertDoesNotCommitTwice`
- `testApplyRejectionRollsBackAndKeepsSource`
- `testConflictRefusalRollsBackWithoutSourceChange`
- `testRollbackRetentionDoesNotDelete`
- `testStageRetentionDoesNotRollback`
- `testMismatchedOperationDoesNotDelete`
- `testProviderStageFailuresDoNotMutateSource` (downloading, offline, read-only, permission, coordination)
- `testCancellationErrorFromStageDoesNotRollback`
- `testLoadFailureDoesNotStage`
- `testUncapturedContextDoesNotStage`

## IOSImageInsertionPolicyTests

- `testTenMebibyteBoundary`
- `testOversizeAfterHEICTranscodeIsRejected`
- `testHEICConversionStagesPNGBytes`
- `testImageIOTranscodesGeneratedHEIC`
- `testAllowedRasters`
- `testMismatchedExtensionOrTypeIsRejected`
- `testSVGInvalidBytesAndExecutablesAreRejected`

## IOSImageInsertionPathTests

- `testSmartPasteRepresentsSpecialFilenames`
- `testWriterDedupedPathIsUsedVerbatim`
- `testIllegalWriterPathsAreNotInserted`
- `testUTF16CaretStaysOnTheCapturedSelection`
- `testPickedFileBytesAreNotTheMarkdownPath`

Module results and the device Files/iCloud/Photos gate are recorded separately in `README.md` after the simulator run. Passing these classes does not close M0.

## IOSImageTaskCancellationTests

- `testCancelledCallerDoesNotBeginPersistence`
- `testTaskCancelDuringNormalizationNeverStages`
- `testTaskCancelDuringStageDrainsOneOwnedRollback`
- `testTaskCancelDuringValidationDrainsWithoutApply`
- `testCancellationDuringFinalSnapshotNeverApplies`
- `testCancelledRollbackRetentionKeepsReceiptAndOwnedIdentity`
- `testTaskCancellationInsideAcceptedApplyStillCommitsOnce`

## IOSImageRasterValidationTests

- `testRealRasterFixturesDecodeAndRemainUnchanged`
- `testSignatureOnlyRastersNeverReachPersistence`
- `testTruncatedRealRastersNeverReachPersistence`
- `testHEICTranscoderMustReturnCompletePNG`

Review-fix execution and exact-source provenance are recorded in `acceptance-review-fixes.md`. The legacy fixture signatures were replaced with complete one-pixel raster data; malformed signatures now belong only to explicit rejection tests.
