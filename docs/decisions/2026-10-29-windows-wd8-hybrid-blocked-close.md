# A close refuses transient and quarantine states, and keeps a stable blocked session only with retention proof

`docs/window-state-gates.md` §9 requires an answer to WD8 before D2. On 2026-10-29 the owner
chose the recommended default, the hybrid in §6.2. Pending editor source or marked text, an
in-flight save or external resolution, a namespace mutation, or quarantine refuses or
defers the close. A stable blocked session (dirty detached, untitled, text-recovery, or
external-conflict) may close and stay warm only when the registry retains its text,
authority, prompts, and LRU protection. Without that proof, the close is refused. An
unseen protected session still participates in termination. W0 has probed interception;
nothing in production sets the veto yet, and D2 implements this policy. Last-root release
(D1b) must preserve authority and fences for any session this rule keeps. Recorded in §9.1.

Alternatives: refusing every blocked close was rejected. Switching documents already keeps
a dirty or conflicted session warm and restores its prompt, and closing can do the same
once retention is proven. Retaining protected state after every close, with no proof, was
rejected, because an unproven close can drop text, authority, or the prompt.
