# E9's typing bullet is accepted on the no-export control, and export's main-thread chunks stay

Owner decision on 2026-11-28, after a Release re-run of the E9 typing probe on `main` at
`15ec386f` (`docs/perf/2026-11-28-export-e9-typing-rerun.md`). The 2026-11-18 record
(`docs/perf/2026-11-18-export-e9-typing-isolation.md`) left two decisions to the owner.
Both are now taken:

1. PDF's G2 first-keystroke clause is answered by the no-export control. The clause
   failed again (first keystroke during a PDF export: median 20.9 ms, max 30.9 ms). The
   no-export burst after the same idle time fails it the same way: after 2–27 s of idle
   its first keystroke takes 21–28 ms. The cost comes from the idle pause, not the
   export. G0 and G1 pass for both products, and typing during an export is faster than
   without one, pooled by stratum and position by position.
2. The export's main-thread chunks are acceptable as they are. In Release one slice
   reaches 73 ms of main-thread CPU (67 ms on 2026-11-18), and load stretches slices
   further in wall time. A keystroke due during one waits for it. The E9 rule asks for
   an owner decision only at hundreds of milliseconds, and the chunks come only while a
   user-started export runs.

What changed: `docs/export-gates.md` checks E9's bullet "Export work never enters the
editor keystroke path; the existing < 16 ms typing budget remains green while export is
active". The evidence is
`AppBackedEditorPerformanceTests/testTypingStaysIsolatedFromActiveHTMLAndPDFExport` and
this record. G2's pre-registered criterion is not rewritten: it failed, and the owner
accepted the explanation of the failure.

Still open: with no export, the first keystroke after an idle pause of about 2 s or
more takes 17–28 ms in the 1 MiB document, against 11–16 ms for the next keystrokes.
#279 removed the extra cost after shorter pauses. This is a §12 typing issue on its own.

Alternatives: find and fix the first-keystroke-after-idle cost first, then re-run the
probe. Rejected for E9 because the cost does not depend on the export, so it stays a §12
item. Move the export's main-thread work off the main thread, or split it into smaller
slices. Rejected for now: the chunks are below the rule's trigger, and the WebKit calls
among them have to run on the main thread.
