# Drain close observations and separate navigation errors

Date: 2026-10-23. Applies to PR #209; IOS-C0-v1 remains unchanged.

Closing must drain the live external-read registry until it is empty, rather
than trusting one captured task array. Provider notifications arriving during
close are deferred behind a write barrier. The close operation classifies those
bytes after its writer queue drains; an already-issued read that sees a newer
clean revision does not recursively issue another read while closing. Unresolved
observations, proposals, dirty source, conflicts and changed authority retain the
writer. Deferred work resumes before autosave can regain admission. A late notice
during asynchronous provider close is retained conservatively and observed after
reopening; it is not silently discarded as a presumed self-save notification.

Ignoring every closing-time notification was rejected: the current UIDocument
save adapter does not atomically compare disk bytes against the saved baseline.
Such an ignore rule could permit a write after an unobserved external change.
The deferred barrier is part of this lifecycle repair, not a claim that the save
adapter supplies compare-and-swap semantics.

Preview test owners must invalidate their controllers before releasing them,
including early throw paths. Independent offline WebViews stop loading and clear
their delegates on success and failure. The remaining legacy PreviewKit waits use
the common throwing readiness helper and bounded JavaScript replies; the offline
bridge aligns with its 8-second default. Functional assertions, required names
and the zero-skip gate remain. No speculative window or host mounting is adopted.
Explicit invalidation addresses a concrete lifetime gap; it does not establish the
origin of the previously printed InvalidTransition failed(deinit) diagnostic.
In particular, identity tests with a nil preview URL load fallback HTML rather
than the production bundle.

Relative-link failures use a concrete scene-controller presentation callback,
wired to the existing shell alert. They never replace the current document's
unavailable reason. Descriptor authority and originating identity/binding checks
still govern navigation; missing targets are reported rather than silently
ignored. This avoids extending any frozen facade or adding a second source of
editable document state.

Validation results are recorded separately for the exact source, full native
module and Preview suites, Mac CI and unsigned Release artifact. Historical
failures remain evidence; a passing subset cannot close the full-preview gate.
