# Export PR G — wide-table design stop

Handoff 20 stops before product implementation. PR #138 is merged at
`d666e64f7907c9d10b9e3037957141b0ea4b1caf`, the base of this investigation.
The existing E0 **GO (paginated)** result remains accepted. Its 420-heading fixture
is not evidence for arbitrary overflowing content. No E5–E9 box closes here.

## Reproduced limitation

`ExportPDFPaginationDesignStopTests.testFixedHeightCaptureDropsHorizontallyClippedTableContentAfterReadyBarrier`
prepends a 12-column Markdown table to the existing E0 tall fixture. It creates F's
network-blocked offscreen controller, waits for the exact `renderForExport` result,
and completes `exportHTML(matchingRenderID:)` (D2). Every table sentinel exists in
both the ready HTML and live DOM. The web view stays unmounted.

It then reuses E0's geometry, fixed-height planner and `createPDF` capture helpers
without copying or modifying their pagination algorithm. Measured on macOS 27.0
(26A428), Debug, 2026-10-04 22:59 Asia/Taipei:

| Measurement | Result |
|---|---|
| Full document bounds | 800 × 28,890 pt |
| Table client width / scroll width | 732 / 2,299 pt |
| Fixed page height / page count | 14,354 pt / 3 |
| E0 vertical sentinels | All 420 exactly once, in order |
| Table columns | 00–03 present; 04–11 missing |
| PDF page boxes | All satisfy E0's default-user-space bounds |
| Expanded-table positive control | 2,333 pt wide; all 12 column sentinels present |

The current `base.css` table has `overflow: auto`, `width: max-content`, and
`max-width: 100%`. Its hidden horizontal content does not enlarge the document's
scroll width. Correct vertical page boundaries therefore still capture a clipped
table. This is content loss inside a scroll container, not evidence of a vertical
page-break defect or a failure of D2 resource readiness.

The positive control changes only the diagnostic DOM's table to `overflow: visible`
and `max-width: none`, settles full geometry again, and captures its first 600 pt.
It proves the missing markers can be captured by the same WebKit/PDFKit path.
It does **not** validate a general layout policy, all pages after relayout, or Print.
No product CSS, bridge, controller API, menu, writer, or HTML behavior changes.

## Retained evidence

- [Original first PDF page](evidence/export-g-design-stop-20261004/original-clipped-table.pdf)
- [Expanded-table positive control](evidence/export-g-design-stop-20261004/expanded-table-control.pdf)
- [Measurements and artifact hashes](evidence/export-g-design-stop-20261004/result.json)

The named test keeps both PDFs as `.xcresult` attachments. A passing diagnostic
means **the loss was reproduced**, not that the feature passed acceptance. Once a
layout policy is implemented, replace this diagnostic expectation with acceptance
assertions requiring every sentinel exactly once; retain the historical evidence.

## Decision needed before continuing

Handoff 20 explicitly says to commit locally, stop and report if the fixed-height
plan cannot guarantee no duplicated or dropped content for a fixture class, including
wide tables. This fixture triggers that stop. D4's product policy is unchanged.

The owner needs to choose how PDF and Print treat horizontal overflow. A candidate
is export-only expansion followed by a bounded fitting/scaling policy. The policy
must define what happens beyond the 14,400-pt width bound, how print paper fits the
same content, and how table/code/math/Mermaid overflow is handled consistently.
The narrow positive control is insufficient to approve that choice. Silently
clipping, omitting columns, using the visible preview, or replacing silent PDF
capture with a print operation cannot satisfy the current contract.

After that decision, extract E0's reusable planning into PreviewKit, generalize
boundary discovery beyond `h3[data-line]`, and test wide tables, KaTeX, Mermaid,
and oversized blocks before exposing either product command. The HTML path must
retain its existing layout and serialization behavior. Panel ordering and the
remaining command/writer/lifecycle decisions are deferred with implementation.

## Verification and limits

- Existing `ExportPDFMechanismSpikeTests`: 7 passed; new design-stop diagnostic:
  1 passed; 8 total, zero failures/skips, under the shared xcodebuild lock.
- Pinned SwiftFormat 0.62.1 archive SHA-256 matched CI; `make lint` passed with
  310 warnings, zero serious violations; `git diff --check` passed.
- The hosted run builds the app and test targets. No separate `make build`, full
  suite, PreviewKit/WorkspaceKit package suites, writer/sandbox or HTML command
  regression run is claimed: this checkpoint changes only diagnostic tests/docs.
- No preview source/bundle or dependency change. No production pagination API is
  exposed before resolving the design stop. No PDF/Print command or owner gate is
  complete. PDF/Print E9 remains **pending idle-machine run**; no timing/RSS
  acceptance was attempted for an unimplemented product path.

Reproduce from this worktree after `make generate` (use a fresh result-bundle path):

```sh
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" xcodebuild \
  -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug test \
  -only-testing:PlainsongTests/ExportPDFMechanismSpikeTests \
  -only-testing:PlainsongTests/ExportPDFPaginationDesignStopTests \
  -resultBundlePath /private/tmp/plainsong-export-g-review.xcresult
```
