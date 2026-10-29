# Share root work while keeping window ownership independent

- Date: 2026-10-30
- Scope: Windows D1c; WD2 in `docs/window-state-gates.md`.

The app registry indexes one live `WorkspaceRootContext` per captured physical root
identity. The index and participant list use weak references; connected facades own
the context, so neither the registry nor a watcher keeps a departed facade alive.
The retained descriptor authority proves aliases against that identity before an
attach. Only the first participant starts the long-lived security scope, watcher
and initial scan. A watcher and in-flight scan resolve a current participant from
the context rather than capturing the creator as their permanent recipient.

The context owns the snapshot and generation. Each window reconciles its own tree,
filter, expansion, selection and missing/current document disposition from that
snapshot, then restarts only its own active search. A peer disposition failure is
reported in that peer and does not prevent later peers from refreshing. Detach
clears only the departing window's search/completion work; final release uses D1b's
root preflight and retained-scope ownership.

Namespace transactions remain app-wide. Their deferred refresh queue and image
placement counts remain per root; drain visits every pending context, retaining an
R2 watcher authority even while R1 owns the transaction. Admission rejects root
overlap and another window's standalone installation before changing the outgoing
root or starting the incoming long-lived grant. A delayed standalone installation
still refuses after that window opens a different root, because admission
classifies the file rather than the window mode. The refusal's Show action focuses
the conflicting window through `KeyWindowRouter`.

Warm-session adoption supersedes installations from an older window synchronously.
Writer activation/publication uses the existing installation and writer lookups;
window enumeration happens only during adoption, install and teardown. A late
writer release or revoke cannot clear the adopted writer. Final revoke still
removes a retired cold registration, and otherwise removes one only when it is the
last reference on a retained root scope. The native editor source contract is unchanged.

Keeping separate root contexts would duplicate scans/watchers and cannot meet WD2.
A strong registry index would retain unreferenced scopes after facades disappear.
Publishing the context or reconciling every window on body edits would add work to
typing. These alternatives are rejected. Named hosted tests and the paired Debug
typing record cover D1c; public window creation/routing remain D2, tabs remain F,
and four-window residency/typing acceptance remains G.
