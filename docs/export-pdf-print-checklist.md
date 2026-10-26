# Export PDF / Print — owner acceptance checklist

**Ready for the owner.** Automated PDF/Print tests now cover the offscreen capture on
every named fixture plus generated long fixtures (A1 acceptance), the save-panel seam,
the standard print-panel path (the `printOperationRunner` and `printDocumentObserver`
seams exercise the real operation with the panel suppressed or the run faked), the ⌘P
File-menu item, and typed capture-error notices. The real `runModal` sheet tests
(suppressed-panel job, real-sheet cancel and supersede, light-theme print output) are
opt-in via `TEST_RUNNER_PLAINSONG_REAL_PRINT=1` — see the last item below. The
sandbox now carries `com.apple.security.print`; without it the app sees no CUPS
destinations. Every box below still needs a real `NSSavePanel`, interactive Print
panel, or VoiceOver pass. Record date, macOS version, exact build commit,
Debug/Release, destination, typed writer outcome, and any remaining paths in
`export-gates.md`. The 2026-10-04 clipping note is historical:
[design-stop evidence](export-pdf-print-design-stop.md).

## PDF: real NSSavePanel / Powerbox, sandboxed build

- [ ] Desktop and Documents: create and overwrite a PDF in each; inspect first,
  last and boundary content and confirm no unrelated filesystem entries appear.
- [ ] Home root: create and overwrite `~/x.pdf` using a fresh selected leaf URL.
- [ ] iCloud Drive: create, overwrite, overwrite an evicted leaf, and record
  materialization/coordination responsiveness and any residue.
- [ ] Accented folder created with `mkdir café`: create and overwrite. If D5
  refuses an alias, record the exact panel URL; do not relax its identity rules.
- [ ] External APFS: subfolder and volume root; verify staging/cleanup or report
  exact refusal and residue paths. Check unsupported filesystem refusal separately.
- [ ] Q3 modes: new `0644` with default umask, overwrite preserving `0640` and
  `0755`, unreadable `0200` refusal; no privilege-bit inheritance.
- [ ] Export a long post (a `perf-500kb.md`-scale document): many pages, each
  ending at a clean break — no clipped lines or split rows — and a document with
  an atomic element taller than the page budget (a very tall diagram, image, or
  formula) shows the dedicated "taller than a PDF page can hold (200 inches)"
  notice, not the generic render error.
- [ ] Oversize element (G3): export a post whose single unbreakable box is too
  large to capture within the raster-area budget (e.g. a very tall image in a
  very wide table row). The export refuses with "An element is too large to
  export as one PDF page (about W × H inches)…" naming the box, no file is
  written, and the app does not crash (hosted:
  `ExportPDFWideRunsEdgeAppTests.testOversizeCaptureAreaBoxFailsTypedAndWritesNothing`).
- [ ] Per-page width: export a post with one very wide table in the middle.
  Pages containing the table are wider than the text-only pages, and the
  text-only pages stay at the normal width (hosted:
  `ExportPrintPaginationAppTests.testWideTableWidensOnlyItsPrintPages`).
- [ ] Wide-run isolation: the same post's wide table lands on its own pages —
  prose never shares a page with the table, no page is blank, and the written
  page count equals the plan (hosted:
  `ExportPDFWideRunsAppTests.testVeryWideTableRunIsolatesAndCapsEveryPage`,
  `testMidWidthTableRunScalesNeighboursStayWhole`,
  `testQuoteListTableShapeLeavesNoBlankTail`). A ~184,770 pt wide table
  exports 5/5 planned pages with the run capped under the raster area budget
  (see `docs/perf-log.md`).
- [ ] A document that *begins* with a very wide table: the first page holds the
  table — no blank leading page, no prose on the run pages, no table on the
  prose pages (hosted:
  `ExportPDFWideRunsEdgeAppTests.testDocumentStartingWithAWideTableHasNoBlankFirstPage`).
- [ ] C2 warning: export a post containing a single minified line wider than
  14,400 pt. The PDF is still written, its wide page is visibly shrunk to fit
  200 inches, and the warning banner names the page and the smallest percentage
  (hosted: `ExportPDFShrunkPagesAppTests`).
- [ ] Long post with a minified line in the middle: in the exported PDF the file
  is written and the shrunk-pages warning appears; in the Print preview only the
  sheet holding the line is small — the prose sheets stay normal size (hosted:
  `ExportPDFWideRunsAppTests.testMinifiedLineRunInALongPostWritesWithAShrunkWarning`).
- [ ] Cancel destination/progress and inspect failure feedback: no destination
  publication and no source, selection, scroll, baseline, identity, recents, tree,
  recovery or visible-preview change; panel focus causes no source autosave.

## Standard Print panel

- [ ] Print opens the standard panel from the completed offscreen render, with
  no preliminary save panel and no mounted export preview. (Hosted:
  `showsPrintPanel` on the real operation; the `runModal` path is exercised by
  the opt-in `TEST_RUNNER_PLAINSONG_REAL_PRINT=1` run.)
- [ ] Paper size/orientation/pagination and system PDF actions work through
  AppKit; Plainsong performs no artifact write for these system destinations.
  The panel's preview shows the per-page scaling (each page's own width, shrunk
  only where content overflows 14,400 pt). Landscape paper produces
  landscape-shaped pages (hosted:
  `ExportPrintPaginationAppTests.testLandscapePrintInfoProducesLandscapeShapedPages`).
  Known limitation: pages are planned to the imageable aspect at panel-open, so
  changing paper size or orientation in the panel makes the pre-planned pages
  scale to fit and may show extra margins (re-planning is out of scope).
- [ ] Panel persistence: change paper size or orientation in the panel and
  complete a Print; the next Print… opens with those choices — only paper
  name, paper size, orientation, and printer carry over from a completed run.
  Cancel a run and confirm the previous choices remain (hosted:
  `ExportPrintPaginationAppTests.testPrintPanelChoicesPersistOnlyWhenTheRunCompletes`,
  `testPrintJobSettingsDoNotPersistBeyondPageSetup`).
- [ ] Cancel and error release the operation and controller, with correct
  feedback and unchanged document/session/visible-preview state. (Opt-in hosted:
  `testCancelDuringRealPrintSheetIsSilent`,
  `testSupersedeDuringRealPrintSheetFinishesAndReleasesObjects`.)
- [ ] Markdown, MDX, math/code/Mermaid, images and wide tables remain complete
  across paper/page boundaries; compare PDF content/theme, not identical breaks.
  (Hosted by default: `ExportPDFMatrixAppTests` asserts real md/mdx/math content
  on the captured print PDF via `printDocumentObserver`; opt-in real sheet:
  `testRealPrintJobProducesLightThemePDFWithEverySentinelOnce` —
  table/code/KaTeX/Mermaid sentinels once, dark ink on light paper.)
- [ ] Print… is on ⌘P and there is exactly one Print item and no Page Setup…
  item in the File menu. (Hosted: `testFileMenuHasExactlyOnePrintWithCommandP`.)
- [ ] Print a long post: multiple paper pages, and the output is dark ink on
  white paper even when the app is in dark theme (B1 always prints light).
- [ ] Tall atomic content prints instead of erroring: a tall phone screenshot
  (~1,584 pt) and a tall Mermaid `flowchart TD` (~30 nodes) each extend one
  page (scaled to fit the sheet) rather than failing — only a run taller than
  ~200 inches shows the "too tall to print (over 200 inches)" notice
  (hosted: `ExportPrintPaginationAppTests.testPhoneScreenshotPrintsOnceWithoutFailing`,
  `testTallMermaidFlowchartPrintsEveryNodeOnce`,
  `testTallImageExtendsItsPrintPageWithoutFailing`).
- [ ] Wide-run Print isolation: a post with a very wide table prints the table
  on its own sheets in both A4 portrait and landscape — no sheet mixes prose
  with the table and no sheet is blank (hosted:
  `ExportPrintWideRunsAppTests.testWideTableRunIsolatesOnA4Portrait`,
  `testWideTableRunIsolatesOnA4Landscape`,
  `testQuoteListTableShapePrintsNoBlankSheets`).
- [ ] A wide table inside a quote and a list: the print preview shows no blank
  trailing sheets after the run (hosted:
  `ExportPrintWideRunsAppTests.testQuoteListTableShapePrintsNoBlankSheets`).
- [ ] An Astro MDX post whose front matter is followed by long `import` lines
  prints on one sheet — the placeholder pills clip their text, so no wide run
  forms (hosted:
  `ExportPrintWideRunsAppTests.testMdxPostWithTwoLongImportLinesPrintsOnOneSheet`).
- [ ] Job settings do not persist: set a page range or copy count (or use the
  panel's Save as PDF action) and complete a Print; the next Print… shows fresh
  job settings — only the paper name/size, orientation, and printer carry over
  (hosted:
  `ExportPrintPaginationAppTests.testPrintJobSettingsDoNotPersistBeyondPageSetup`).
- [ ] Opt-in real-printer check (requires a CUPS destination; skips otherwise):
  `TEST_RUNNER_PLAINSONG_REAL_PRINT=1 xcodebuild test -project Plainsong.xcodeproj -scheme Plainsong -only-testing:PlainsongTests/ExportPrintSheetAppTests`
  — covers all three real-panel tests: one job-saving print (light theme, every
  sentinel once), a real-sheet cancel, and a real-sheet supersede. Do not add,
  remove, or change printers.

## Keyboard and VoiceOver

- [ ] File commands, panels, progress/Cancel and notices can be reached and
  operated with keyboard alone, with sensible focus return after cancellation.
- [ ] VoiceOver labels, announcements, placeholder counts, failure and residue
  recovery information are understandable and complete.
- [ ] Run with source-only, source+preview and Experimental WYSIWYG, and with
  light, dark and resolved-system themes. Untitled/non-workspace windows refuse.

Performance remains **pending idle-machine run** for formal PDF/Print E9. Record that
run as `docs/perf/YYYY-MM-DD-<slug>.md`. The A1 acceptance suite already records
per-fixture pages/widest page/smallest scale/capture time under recorded load in the
`docs/perf-log.md` archive, including the opt-in `large-1mb.md` capture; these are
recorded-load observations, not budgets, and no owner-acceptance result is inferred
from them.
