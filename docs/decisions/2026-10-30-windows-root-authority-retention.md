# Keep root authority for sessions preserved by another window

- Date: 2026-10-30
- Scope: Windows D1b review follow-up, PR #239.

The last-root preflight includes every session whose retained authority or installed
membership belongs to that root. Only the release set excludes sessions another
connected window shows or installs. R1 quarantine still blocks R1 closure; another
root's state remains outside this preflight.

A preserved R1 session retains a reference to the original security-scope owner in
the app registry. Retirement of the closing window's sessions cannot stop that
scope. Eviction or final ownership release drops the reference only after all
registry owners and pending work are gone. Installation lifecycle records its
window weakly, so a delayed editor teardown in the closing window enters normal
retirement instead of being mistaken for another window's installation.

Rejecting every close with a preserved session would be safe but would postpone
D1b's cross-window release behavior. Keeping the scope on the closing facade would
make its lifetime depend on that facade. Registry ownership follows the session
instead, without adding work to source publication.

Standalone replacement has no workspace-root authority to filter by. Its release
set instead includes that window's shown session and live editor installations,
so composition can publish until retirement's final revoke. Other windows and
unrelated warm sessions remain outside the replacement preflight. The existing
standalone composition, late Reload and failed-destination tests cover this
boundary; a cross-window test verifies the narrower inventory.

Lease release is retried after root release removes warm ownership, after the last
installation revokes, and after an external inspection or resolution read finishes.
A running read retains the scope through its actual completion; eviction does not
cancel a detached read and immediately stop the scope underneath it. The final
revoke still removes a retired cold registration, and otherwise removes one only
when it is the last reference on a retained root scope. An unshown untitled
session keeps its registration and can be shown again. Discard removes the weak
installation/window record together with the installation itself.
