# The same file focuses the window that already shows it; refusal is only the fail-closed fallback

`docs/window-state-gates.md` §9 requires an answer to WD1 before D1. On 2026-10-29 the owner
chose the recommended default. A request that would make a file current in a second window,
including a sidebar click and a preview link, focuses the window that already shows that
file. The requesting window is unchanged, and there is no error. Refusal (option c) is only
the fail-closed fallback when focusing is impossible, such as a window mid-close or
presenting a sheet. D2 implements this. This record adds no New Window command, does not
relax `WindowOpenAdmission`, and does not allow tabbing. Recorded in §9.1.

Alternatives: sharing one `DocumentSession` across two editors (b) was rejected. It needs
per-keystroke propagation, a shared undo model, and IME and WYSIWYG behavior the §12 typing
gate forbids, and it is not for v1. Refusing every second open (c) was rejected as the
normal path, because the user would have to find the window. It stays only as the fallback
above.
