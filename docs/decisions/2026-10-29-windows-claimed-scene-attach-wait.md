# Wait for a claimed workspace scene before requesting another

The workspace metadata callback attaches the window asynchronously. A File command
or the launch callback can run after `WindowFacadeHolder` claims the owner but
before that attach. Testing only for an attached window could request a second
scene, which receives a refused sibling and briefly appears before closing.

`KeyWindowRouter.isOwnerClaimed` distinguishes a scene under construction from the
owner merely being tracked during app initialization. Both launch completion and
File/Quit queuing wait for a claimed scene. An unclaimed owner can still request
its first scene after launch even though it is already tracked.

The existing three-second wait remains bounded. On expiry, pending commands and
errors are discarded and the next command may retry despite a lingering claim.
An owner attach clears that retry allowance, including a late attach after expiry,
so the next Dock reopen again gets its normal attach wait.

Hosted tests control the claim-to-attach gap at launch and during Dock reopen,
verify that only the latest pending command runs on the owner, and verify retry
after expiry plus reset after a successful attach. Native Dock/Finder behavior
remains owner smoke.

Alternatives: treating every tracked facade as an incoming scene would strand an
owner that was initialized without a scene. Waiting on a claim forever would
restore the stuck queue. Adding another yield or an arbitrary delay would still
make duplicate-scene prevention depend on callback timing.
