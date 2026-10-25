# Prove iOS grant authority after synchronous retirement callbacks

Date: 2026-10-25. Contract IOS-C0-v1 remains unchanged.

Replacing a safely closed scene's workspace retires the old grant through the same
access provider. Its invalidation observers execute synchronously and can revoke a
provisional destination. A lease proved before that retirement could therefore
leave a directory-only replacement falsely marked current without opening a writer.

Retire the old grant first, obtain a fresh lease proof afterward, and hold that
proof through current-grant/snapshot adoption. Release it only after adoption and
after clearing the retired scope's unavailable reason. A synchronous revocation
from release then sees the new current grant and preserves its unavailable state.
No await, second provider, writer replacement or source change is introduced.

Two controlled regressions call the shared adoption helper on directory scopes:
one revokes the destination from an old-scope invalidation observer; the other
revokes from proof release and checks that current authority stays unavailable.
The latter uses a narrow callback on the existing test lease, with idempotent
release. Native execution and current-head CI belong to the integration owner;
prior 7afd4cd results are not execution evidence for this change.

Rejected alternatives: retaining a pre-retirement proof, trusting a stored grant
value as live authority, and clearing unavailable state after releasing the proof.
