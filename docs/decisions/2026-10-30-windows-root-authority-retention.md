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

## Follow-up, 2026-11-06 (review of `89a995c`)

Five boundary cases failed in hosted reproductions before this repair
(`WindowRootReleaseBoundaryAppTests`).

- The closing window's own document and live installations join the preflight and
  the release set wherever they live, with or without a root. A standalone file still
  shown after an empty folder opened belonged to no root, so replacing that folder
  skipped its save and retirement; main saved it. Other windows' sessions still follow
  root membership.
- Only a preserved session that the root's authority proves it owns retains the
  root's scope. During a root's first scan nothing is proven, so a replacement then
  cannot hand the new folder's grant to a document another window shows.
- The shared foreground autosave belongs to the home façade (`scheduleAutosave()`),
  so only the home façade's close cancels it. The shared statistics task stays
  last-writer-wins: any window refreshes its shown document on it, and a lost refresh
  only delays a word count.
- An operation recovery blocks the closure of the root its recorded locations name
  and of any session it still holds. Another root's recovery no longer blocks
  (W6 bullet 6). A record that could not be resolved names no authority and still
  blocks every closure. The in-progress transaction and the recovery store-load fences
  stay global.
- When the last window switches away from a cold, unretired, uninstalled session whose
  registration only its retained root scope still needs, the registration is dropped
  and the scope can stop. The final revoke already did this in the other order.

Alternatives: refusing the replacement while the window shows a document outside its
root would block an ordinary standalone-file-to-folder flow. Saving that document
without retiring it would differ from standalone replacement, where retirement lets
composition publish until the final revoke.
Cancelling the foreground autosave whenever the closing window's own document leaves
would still let a sibling cancel the home window's timer. Keeping every recovery
global would keep W6 bullet 6 false for operation recoveries.
