# Workspace Search is complete; physical ⇧⌘F is residual owner evidence

Workspace Search had shipped behind its product gates since August, but its Definition of Done
(`docs/workspace-search-plan.md` §7) stayed open on two items, recorded in R20: no serialized
`make test` had ever run `PlainsongUITests`, and the 2026-09-18 proposal to treat physical ⇧⌘F
as residual owner evidence was waiting for the maintainer.

**The UI runner failure was an authentication prompt.** `automationmodetool` on the dev Mac
reports "Automation Mode is disabled. This device requires user authentication to enable
Automation Mode." When `PlainsongUITests-Runner` starts, macOS asks for that authentication;
in September nobody was there and it was cancelled ("Authentication canceled"). On 2026-10-24
the owner sat at the Mac and approved it. At `3ae52db` (`main` at `1428bf1` plus the
hidden-sidebar fix in `2026-10-24-shortcut-reveals-hidden-sidebar.md`), one
`caffeinate -di make test` exited 0: every package suite and sandbox probe, `PlainsongUITests`
31/31 with none skipped, `PlainsongTests` 995 with 0 failures, `PerformanceTests` 31 with 0
failures including WS4B 14/14, and `preview-src` 154/154. `make build` and `make lint` (pinned
SwiftFormat 0.62.1) also passed. The runner waits only 60 seconds for approval: two other
attempts that day timed out, so a UI-inclusive `make test` needs the owner present when the
hosted stage starts.

**Physical ⇧⌘F stays owner smoke.** The owner confirmed the 2026-09-18 proposal and re-ran the
check on the built-in keyboard on `3ae52db` under ABC and Zhuyin: Files↔Search toggle with the
query and results kept, query-field focus, a hidden sidebar returning in Search from both
modes, and the View menu item. With that, every §7 box is checked, Workspace Search is
complete, and R20 is closed. XCUITest and the hosted `NSEvent` gates remain synthetic evidence
and do not stand in for the physical keyboard.

Alternatives: enabling Automation Mode without authentication
(`automationmodetool enable-automationmode-without-authentication`) was offered; it changes a
security preference that only the owner can set, and the owner chose to approve the prompt.
Accepting the run that passed every bundle but stopped at `test-preview` (no `node_modules` in
a fresh worktree), plus a separate `test-preview` pass, was offered; the owner chose a single
clean invocation. Adding a repeatable physical-keyboard gate was rejected again: it needs
hardware input no test session can produce.
