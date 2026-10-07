# Export PDF / Print — owner acceptance checklist

**Ready for the owner.** Automated PDF/Print tests now cover the offscreen capture on
every named fixture plus generated long fixtures (A1 acceptance), the save-panel seam,
the real `runModal` print path (suppressed-panel job, real-sheet cancel and supersede,
light-theme print output), the ⌘P File-menu item, and typed capture-error notices. The
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
- [ ] Cancel destination/progress and inspect failure feedback: no destination
  publication and no source, selection, scroll, baseline, identity, recents, tree,
  recovery or visible-preview change; panel focus causes no source autosave.

## Standard Print panel

- [ ] Print opens the standard panel from the completed offscreen render, with
  no preliminary save panel and no mounted export preview. (Hosted:
  `showsPrintPanel` on the real operation, `runModal` path exercised.)
- [ ] Paper size/orientation/pagination and system PDF actions work through
  AppKit; Plainsong performs no artifact write for these system destinations.
- [ ] Cancel and error release the operation and controller, with correct
  feedback and unchanged document/session/visible-preview state. (Hosted:
  `testCancelDuringRealPrintSheetIsSilent`,
  `testSupersedeDuringRealPrintSheetFinishesAndReleasesObjects`.)
- [ ] Markdown, MDX, math/code/Mermaid, images and wide tables remain complete
  across paper/page boundaries; compare PDF content/theme, not identical breaks.
  (Hosted: `testRealPrintJobProducesLightThemePDFWithEverySentinelOnce` —
  table/code/KaTeX/Mermaid sentinels once, dark ink on light paper.)
- [ ] Print… is on ⌘P and there is exactly one Print item and no Page Setup…
  item in the File menu. (Hosted: `testFileMenuHasExactlyOnePrintWithCommandP`.)

## Keyboard and VoiceOver

- [ ] File commands, panels, progress/Cancel and notices can be reached and
  operated with keyboard alone, with sensible focus return after cancellation.
- [ ] VoiceOver labels, announcements, placeholder counts, failure and residue
  recovery information are understandable and complete.
- [ ] Run with source-only, source+preview and Experimental WYSIWYG, and with
  light, dark and resolved-system themes. Untitled/non-workspace windows refuse.

Performance remains **pending idle-machine run** for formal PDF/Print E9. The A1
acceptance suite now records per-fixture pages/max height/scale/capture time under
recorded load in `docs/perf-log.md`, including the opt-in `large-1mb.md` capture
(56 pages, ~18 s under load 8); these are recorded-load observations, not budgets,
and no owner-acceptance result is inferred from them.
