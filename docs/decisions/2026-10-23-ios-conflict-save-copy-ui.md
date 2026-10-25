# iOS conflict Save a Copy uses a separate destination issuance

Date: 2026-10-23. Scope: source plus preview v1; IOS-C0-v1 unchanged.

The conflict banner already has an optional `resolveConflictCopy` surface. The
store already implements create-new `saveCopy`, preserving the original session,
saved baseline and conflict. Add a small coordinator and self-contained presenter
over those existing services; no second store, access manager or overwrite API.

Before a name form or picker, capture document identity, exact session reference,
editor binding, revision and exact UTF-8 source, dirty state, document location,
editor/store access generation, original grant and conflict recovery issuance.
The suggested Markdown/MDX leaf includes an issuance suffix. The editable name is
validated as one leaf. A separate folder picker issuance owns that exact name;
cancelled, duplicate, altered or stale picker replies cannot mint new authority.

Open the explicitly selected destination folder through the scene's existing
access service, hold its own lease, refresh and reject occupied names. Revalidate
the origin and destination after every await. Acquire the existing scene
transition fence and synchronously update editor access before calling the
original store's `saveCopy`. Check the returned source, revision and destination.
The destination create-new operation remains the authority against a concurrent
creator, including when preflight did not list the name.

Cancellation never releases a lease while provider work is still draining. After
the store returns, release and invalidate only the independently issued
destination grant; finish only the transition this operation acquired. Keep the
origin handle, grant, dirty state, native source/selection/Undo, conflict and
recovery. Successful copy feedback explicitly says the original is still in
conflict. If source/access changes or an indeterminate create fails, a copy may
already contain older bytes: retain the newer source, report that possibility,
and do not delete a file whose ownership was not returned.

Terminal success or failure feedback is queued until provider work drains and
the name sheet's actual dismissal hands it to the single outer alert. Validation
errors stay in a separate form notice. No sleep or repeated presentation is used.
Feedback promises to retain any existing recovery draft, without inventing a
record when the captured conflict has none.

The implementation can compile independently of recovery UI and runtime changes.
Integration installs `IOSConflictCopyPresenter` once and routes the existing
surface to `requestSaveCopy()`. The shared controller's asynchronous external
resolution also needs the transition fence: a resolution already awaiting before
copy admission must make the later copy refuse, rather than relying only on its
post-await source checks. This shared change belongs to the integration owner.

Alternatives rejected: reusing `openPickedURL` would close or replace the origin;
the system export/move picker could replace authority and provide overwrite
semantics; a second writer or a direct `Data.write` would bypass the store's
revision and create-new guards; deleting a possible earlier copy after failure
would require ownership proof the store contract does not expose.

Controlled tests and one real-provider workflow are added. Their execution is
pending the integration owner's serialized native run. The real workflow uses
actual access, UIDocument, native editing, durable recovery and coordinated
creation; it enters conflict through the existing testable store method, so it
does not claim physical Files/iCloud conflict delivery or picker UI acceptance.
Device iPad/OS26, VoiceOver, external keyboard and performance gates remain open.
