# Export PDF / Print — owner acceptance checklist

**Not ready to run:** PR G is stopped before commands are implemented. See
[the design-stop evidence](export-pdf-print-design-stop.md). Every box below is
owner-only and remains unchecked; diagnostic or injected-panel tests cannot close it.
After implementation, record date, macOS version, exact build commit, Debug/Release,
destination, typed writer outcome, and any remaining paths in `export-gates.md`.

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
  no preliminary save panel and no mounted export preview.
- [ ] Paper size/orientation/pagination and system PDF actions work through
  AppKit; Plainsong performs no artifact write for these system destinations.
- [ ] Cancel and error release the operation and controller, with correct
  feedback and unchanged document/session/visible-preview state.
- [ ] Markdown, MDX, math/code/Mermaid, images and wide tables remain complete
  across paper/page boundaries; compare PDF content/theme, not identical breaks.

## Keyboard and VoiceOver

- [ ] File commands, panels, progress/Cancel and notices can be reached and
  operated with keyboard alone, with sensible focus return after cancellation.
- [ ] VoiceOver labels, announcements, placeholder counts, failure and residue
  recovery information are understandable and complete.
- [ ] Run with source-only, source+preview and Experimental WYSIWYG, and with
  light, dark and resolved-system themes. Untitled/non-workspace windows refuse.

Performance remains **pending idle-machine run** for the eventual production
PDF capture path on `large-1mb.md` and a math/code/Mermaid-heavy fixture. No
performance or owner-acceptance result is inferred from the current diagnostic.
