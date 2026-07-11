# Image Thumbnails — Sub-Gate Specification

> **Status: I0–I10 checked with evidence. PR #83 wires image thumbnails only into the
> off-by-default Experimental WYSIWYG mode for folder workspaces.**
> `docs/wysiwyg-release-checklist.md` §E records that narrow inclusion. This document is the
> dedicated sub-gate (the link-folding pattern, `docs/link-folding-gates.md`, applied to the
> next construct). The App supplies the WorkspaceKit-backed loader only when the Experimental
> flag, WYSIWYG layout, and mechanism-health gates already permit WYSIWYG; source modes,
> kill-switch fallback, single-file mode, and stable/default promotion remain unchanged.

Created 2026-07-06 after the link-folding sub-gate completed (PRs #65/#67/#68).
See `agent.md` §13, `docs/wysiwyg-release-checklist.md` §A/§E, and the 2026-06-26
zero-width-projection Decision Log entry.

## 1. Scope

- **In scope:** inline images `![alt](relative-path)` whose source resolves to a **local
  raster file inside the open workspace**, under the exact asset policy the preview already
  enforces (PR #24/#27): PNG, JPEG, GIF, or WebP, ≤ 10 MiB, path containment, no symlink
  escape. While the caret is outside the image's source range, the editor shows a bounded
  thumbnail; reveal-on-touch restores the raw `![alt](src)` text.
- **Stays raw text (v1):** remote `http(s)` sources (the editor performs **no network I/O**;
  the preview pane's separate opt-in policy is unaffected), SVG and any non-allowlisted
  format, oversized files, sources outside the workspace, reference-style images, and
  images in single-file mode without directory scope (sandbox cannot read siblings).
- Animated GIF renders its first frame only; no playback in v1.

## 2. Why images are harder than links

Links proved the asymmetric-hidden-span model; images break two assumptions even that
never touched:

1. **Non-zero-width presentation.** Every shipped fold collapses to zero advance. A
   thumbnail occupies real geometry — width, height, baseline — so line layout, caret
   navigation, hit-testing, and viewport math all meet a visual whose size differs from its
   source text for the first time.
2. **The U+FFFC tension.** `NSTextAttachment` is the native way to put a picture in text,
   but attachments ride an object-replacement character, and the repo's non-negotiables are
   a canonical backing string and exact-raw copy/AX. The existing `NSTextContentStorage`
   paragraph projection substitutes characters **only in the projected paragraph** (backing
   stays raw) — whether an attachment can live purely in projection without leaking U+FFFC
   into copy, AX, or undo is exactly what the I0 spike must prove.
3. **Asynchronous I/O on the presentation path.** Decode/downsample must happen off the
   main actor with a cache; layout must update when a thumbnail arrives without touching
   typing latency (§12: keystroke < 16 ms is a hard gate even mid-load).
4. **Sandbox reality.** Reading pixels requires security-scoped access via WorkspaceKit —
   the editor must reuse the existing workspace-access and asset-policy plumbing, not grow
   a second file-access path.

## 3. Mechanism options (I0 spike decides; record in the Decision Log)

| Option | Sketch | Pros | Risks | Stance |
|---|---|---|---|---|
| **A. Projection-only attachment** | The zero-width projection already returns a substituted `NSTextParagraph`; project the image's source range to an `NSTextAttachment` (+ padding) in the projected paragraph only. Backing string stays raw. | Native sizing/layout/hit-testing; one mechanism family with the shipped projection. | Attachment cell lifecycle inside a projected paragraph; caret/offset mapping across a 1-visual-to-N-chars span; must prove **zero** U+FFFC in copy/AX/undo. | **Primary candidate — spike first** |
| **B. Overlay adornment view** | Fold the `![alt](src)` chrome like a link; draw the thumbnail as a separate `NSView` positioned from layout-fragment geometry. | No attachment, no U+FFFC risk anywhere. | Text layout reserves no vertical space → image overlaps following lines unless line height is faked; scroll/reuse bookkeeping. | Fallback if A fails the raw-copy/AX proof |
| **C. Custom `NSTextLayoutFragment`** | Owner-drawn fragment with image geometry. | "Correct" TextKit 2 answer on paper. | STTextView owns the layout-fragment delegate (rejected before for the same reason, 2026-06-26). | Rejected unless STTextView grows an API |
| **D. Mutate source / insert real ORC** | Put U+FFFC in the backing string. | Trivial layout. | Violates canonical-source; breaks copy/AX/undo invariants. | Rejected |

## 4. Gates

### I0 — Mechanism spike (blocks everything, mirrors checklist §A)
- [x] A spike PR proves the chosen mechanism on one hardcoded image: geometry sane
  (no phantom line inflation), backing string byte-identical, copy/paste/AX/undo raw,
  reveal-on-touch restores raw text, and — decisive for option A — **no U+FFFC anywhere**
  in pasteboard or `AXValue` output. Decision Log entry records the choice and rejected
  alternatives before any production PR.

### I1 — Model correctness
- [x] Image regions parse with exact source/reveal ranges; eligibility (local, in-workspace,
  allowlisted raster, ≤ 10 MiB) decided per image; ineligible images provably stay raw.
  Reference-style images stay raw; double-quoted `![alt](url "title")` titles keep exact
  ranges (including surrounding quotes). Evidence (2026-07-10):
  - MarkdownCore: `MarkdownImageRegionsTests`
    (`testInlineImageRegionsRoundTripExactUTF16Ranges`,
    `testInlineImageRegionRejectsReferenceAutolinkEmptySourceAndMalformedForms`,
    `testThumbnailEligibilityAllowsSharedRasterExtensions`,
    `testThumbnailEligibilityRejectsIneligibleSources`,
    `testThumbnailEligibilityIsDeterministicForIdenticalInputs`)
  - EditorKit shared visible-range parser (no extra pass): `WYSIWYGImageRegionModelTests`
    (`testI1SharedVisibleParserProducesExactImageRegionsWithoutPresentation`,
    `testI1ReferenceAutolinkEmptySourceAndMalformedFormsDoNotEmitImageRegions`,
    `testI1ImageRegionsDoNotReceiveFoldPresentationAttributes`)
  - Policy constants centralized on `MarkdownImageAssetPolicy` and consumed by PreviewKit
    `AssetURLPolicy` + WorkspaceKit `WorkspaceImageAssetStore` (no App/UI/load path yet).

### I2 — Render policy
- [x] Thumbnail is bounded (fit editor width, capped height, ~300 pt class), decoded
  **downsampled** (`CGImageSource` thumbnailing, never full-size bitmaps for huge photos);
  a deterministic placeholder shows while loading or on failure (missing/corrupt file
  never blanks or shifts unrelated lines); file change on disk refreshes the thumbnail.
  **Loader evidence (2026-07-10):** decode/downsample + mtime
  cache key in `WorkspaceImageThumbnailProviderTests`
  (`testDownsampledDimensionsAreBounded`, `testDocumentRelativePathAndGIFFirstFrame`,
  `testJPEGAndWebPDecode`, `testCacheHitMissMtimeInvalidationAndByteBudgetEviction`).
  **Presentation evidence (2026-07-11, internal hook only):**
  - `WYSIWYGImageThumbnailPresentationTests`
    (`testProjectedRegionUsesOneAttachmentAndEqualLengthZeroWidthPadding`,
    `testStandaloneGeometryReservesOnlyImageLineAndPreservesViewport`,
    `testInlineImageDoesNotInflateOtherWrappedVisualLines`).
  - `testReadyThumbnailFitsEditorAndUsesPixelAspectInsideThreeHundredPointCap` proves the
    fixed canvas fits the editor and the decoded pixels aspect-fit within the 300 pt cap.
  - `testLoadingPlaceholderAndReadyThumbnailShareGeometrySelectionAndScroll` and
    `testMissingFailureAndCorruptReadyDataKeepDeterministicAltPlaceholder` prove loading,
    missing, failed, and corrupt paths never blank or reflow unrelated lines.
  - `testMultipleImagesShareOneLineWithFoldedLinkAndCoalesceDuplicateLoad` covers multiple
    image regions in one paragraph alongside the existing folded-link projection.
  - `testRefreshProxyReloadsOnlyAffectedPathAndPreservesSelectionAndScroll` proves the
    EditorKit refresh entry point reloads and reprojects only matching workspace paths.
  - **App/FSEvents evidence (2026-07-12, PR #83):**
    `AppStateTests.testWorkspaceReloadInvalidatesOnlyChangedAllowlistedRasterPaths` wires the
    existing external workspace-reload path to that proxy for changed, added, and removed
    allowlisted raster paths while excluding unchanged and SVG paths.

### I3 — Caret & selection
- [x] Reveal-on-touch; caret snapping at both edges of the image span (the C.2 policy over
  a non-zero-width visual); selections keep raw UTF-16 offsets, never clamped (C.3).
  **Evidence (2026-07-11):** `WYSIWYGImageThumbnailNativeGateTests`
  (`testI3ArrowTraversalSnapsAcrossReadyThumbnailInBothDirections`,
  `testI3ArrowTraversalSnapsAcrossPlaceholderInBothDirections`,
  `testI3InteriorCaretSnapsByTravelDirectionAndNearestOnClick`,
  `testI3ShiftSelectionEnteringLeavingAndSpanningImageKeepsRawOffsets`,
  `testI3EmojiAndCJKInAltAndPathAtEdgesDoNotTrapCaret`,
  `testI3ImageAdjacentToFoldedLinkOnSameLineKeepsIndependentSnapping`,
  `testI3RevealOnTouchClearsImagePresentationMarker`).

### I4 — Copy/paste
- [x] Whole/partial/boundary selections copy exact raw `![alt](src)` bytes (B7); paste into
  folded/revealed image regions mutates source normally; copy never emits U+FFFC.
  **Evidence (2026-07-11):** `WYSIWYGImageThumbnailNativeGateTests`
  (`testI4WholePartialBoundaryAndAltToPathSelectionsCopyExactRawPlainAndRTF` — whole,
  partial, leading/trailing boundary, and alt→path partial; plain + RTF; zero U+FFFC and
  zero U+200B;
  `testI4PasteIntoFoldedAndRevealedImageRegionsMutatesSourceNormally`).
  Builds on #80 `testWholePartialAndBoundaryCopiesStayRawForPlainAndRTF` /
  `testRawPasteMutatesOnlyBackingSource` without duplicating those I0 invariants.

### I5 — IME (owner-run)
- [x] `PLAINSONG_RUN_ACTUAL_IME=1` Zhuyin + Pinyin composition immediately before/after an
  image span: no corruption, no caret escape, no premature commit, image presentation skipped
  during marked text, and the ready thumbnail/loading placeholder presentation reapplied after
  commit. **Owner evidence (2026-07-12, PR #83):**
  - `com.apple.inputmethod.TCIM.Pinyin` (`Pinyin – Traditional`,
    `TISTypeKeyboardInputMode`) passed all four image-boundary scenarios: immediately before
    and after the image with a ready thumbnail, then immediately before and after with a
    loading placeholder.
  - `com.apple.inputmethod.TCIM.Zhuyin` (`Zhuyin – Traditional`,
    `TISTypeKeyboardInputMode`) passed the same four scenarios.
  - The complete `WYSIWYGActualIMEEventGateTests` owner run executed 10 tests with 0 failures
    in 106.508 seconds; neither input method was skipped.

### I6 — Pointer
- [x] Real-`NSEvent` click on the thumbnail places the caret and reveals (no drag-resize,
  no open-in-Preview in v1); boundary clicks don't trap; drag selection across the image
  copies raw Markdown.
  **Evidence (2026-07-11):** `WYSIWYGImageThumbnailNativePointerGateTests`
  (`testI6RealPointerClickOnThumbnailBodyPlacesCaretRevealsAndDoesNotOpenPreview`,
  `testI6RealPointerClicksAtBothVisualBoundariesDoNotTrapCaret`,
  `testI6RealPointerDragSelectionAcrossImageCopiesExactRawMarkdown`,
  `testI6ShiftClickExtensionAcrossImageKeepsRawOffsets`).

### I7 — Accessibility
- [x] `AXValue` is the exact raw source; the thumbnail exposes the alt text as its
  accessibility description.
  **Evidence (2026-07-11):** #80
  `testAccessibilityKeepsRawValueAndSelectedTextAndExposesAltDescription` plus
  `WYSIWYGImageThumbnailNativeGateTests`
  (`testI7AXValueAndSelectedTextStayExactRawWithThumbnailPresent`,
  `testI7AttachmentExposesAltTextAndEmptyAltUsesImageFallback` — empty alt uses the
  deterministic `"Image"` accessibility fallback matching the placeholder chip label).

### I8 — Performance & memory
- [x] Visible-range recompute on `Fixtures/large-1mb.md` stays ≤ 50 ms with image folding
  active (CI-informational per R15, hard locally); typing latency stays < 16 ms **while
  thumbnails are loading**; decode is off-main; cache is keyed by path+mtime with a bounded
  memory budget recorded in `docs/perf-log.md`.
  **Evidence (2026-07-11):**
  - `WYSIWYGImageThumbnailI8PerformanceGateTests.testI8VisibleRangeRecomputeWithImageFoldingStaysUnderFiftyMilliseconds`
    (uses existing `Fixtures/large-1mb.md` image syntax; no fixture generator change)
  - `testTypingOnLargeFixtureStaysUnderBudgetWhileThumbnailLoadsAreInFlight` (kept green)
  - `testTextChangeCancelsAndDropsStaleLoadBeforeNewPlanApplies`,
    `testDocumentChangeCancelsOldGenerationAndStartsFreshRequest` (coalescing)
  - `testI8LoaderDecodePathRunsOffMainThread`
  - `testI8CacheByteBudgetIsThirtyTwoMebibytes` + `docs/perf-log.md` (32 MiB =
    `WorkspaceImageThumbnailProvider.defaultCacheByteBudget`)

### I9 — Undo/redo
- [x] Presentation never enters undo; editing alt/path after reveal undoes as plain text;
  fold state recomputes after undo without stale attachments/adornments.
  **Evidence (2026-07-11):** `WYSIWYGImageThumbnailNativeGateTests`
  (`testI9PresentationNeverRegistersUndoIncludingPlaceholderReadyAndRefresh`,
  `testI9EditingAltAndPathAfterRevealUndoRedoAndRebuildProjection`,
  `testI9NestedUndoIsolationFromPresentationTestsStaysGreen` — keeps #80 nested isolation
  green as a named I9 reference).

### I10 — Security & sandbox
- [x] Pixel loading goes through WorkspaceKit's security-scoped access and the shared
  raster allowlist/size/containment policy (one policy, no editor-side fork); no network
  I/O from the editor path, asserted by test. Evidence (2026-07-10):
  - `WorkspaceImageThumbnailProviderTests.testRemoteDataAndFileSourcesStayRawWithoutIO`
  - `testParentTraversalAndSymlinkEscapeStayRaw`
  - `testAllowlistAndOversizeRejectedBeforeRead`
  - `testSingleFileModeHasNoDirectoryScope`
  - `testContainedURLRejectsTraversalAndAcceptsNestedPaths`
  Shared containment lives in `WorkspaceRootContainment` (also used by
  `CompletionWorkspaceProvider` / `WorkspaceImageAssetStore`); eligibility is
  `MarkdownImageThumbnailPolicy` + `MarkdownImageAssetPolicy`.

## 5. Exit criteria

I0–I10 are checked with named automated and owner-run evidence. PR #83 supplies the
WorkspaceKit-to-EditorKit adapter and `_developmentImageThumbnails` only when the existing
Experimental flag, WYSIWYG layout, and mechanism-health gates select
`.inlineFoldRevealWithLinkFolding`, and only when a folder workspace provides contained
directory scope. The existing FSEvents/external-reload path invalidates changed raster paths;
single-file mode provably supplies no loader and stays raw. This enables image thumbnails
**only inside the off-by-default Experimental WYSIWYG mode** and is recorded in the 2026-07-12
Decision Log entry. Stable/default promotion remains governed by
`docs/wysiwyg-release-checklist.md` §F/D.4 and is not claimed. Remote image fetching, SVG,
reference images, animation playback, resize handles, and open-in-Preview behavior are out of
scope for v1 and each needs its own future gate.
