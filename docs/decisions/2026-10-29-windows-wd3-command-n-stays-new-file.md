# ⌘N stays New File; New Window is ⇧⌘N, and New Tab is ⌘T under PR F

`docs/window-state-gates.md` §9 requires an answer to WD3 before D2. On 2026-10-29 the owner
chose the recommended default. ⌘N stays New File, as `agent.md` §6.4 already binds it.
File › New Window is ⇧⌘N and opens an empty window (§6.1). New Tab is ⌘T, and only once
PR F enables native tabs. D2 adds the commands. Until then creation stays guarded: this
decision does not add New Window, relax `WindowOpenAdmission`, or allow tabbing. Recorded
in §9.1.

Alternatives: giving ⌘N to New Window and moving New File to ⌥⌘N (B) was rejected, because
it breaks §6.4, the M4 checklist, and existing muscle memory. Shipping no New Window
command (C) was rejected, because the user could not open an empty window, and the tab
bar's "+" is not a specified command.
