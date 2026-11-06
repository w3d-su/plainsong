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
errors are discarded and an unattached owner claim is released, so the next scene
can claim the owner instead of receiving a refused sibling. The expired scene keeps
the claim token it was issued. If its window attaches later, that token is no
longer current: `attach` does not map the window onto the owner, does not install
the owner's close observer, and closes the window with `close()` so a vetoing
delegate cannot keep it. A replacement scene's window, prompts, and claim therefore
survive the old window arriving or closing in either order. A successful attach of
the current claim still clears the retry allowance, so the next Dock reopen waits
for that scene.

Hosted tests control the claim-to-attach gap at launch and during Dock reopen,
verify that only the latest pending command runs on the owner, and verify retry
after expiry plus reset after a successful attach. They also open a new holder
after expiry and deliver the retired and replacement windows in both orders.
Native Dock/Finder behavior remains owner smoke.

Alternatives: treating every tracked facade as an incoming scene would strand an
owner that was initialized without a scene. Waiting on a claim forever would
restore the stuck queue. Adding another yield or an arbitrary delay would still
make duplicate-scene prevention depend on callback timing.
