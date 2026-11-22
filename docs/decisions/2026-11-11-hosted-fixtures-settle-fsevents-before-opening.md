# Hosted test fixtures wait for FSEvents to record their own writes before opening the workspace

A hosted fixture writes its files and opens them as a workspace a few milliseconds later.
`WorkspaceEventWatcher` starts its FSEvents stream "since now", but FSEvents numbers an
event when its daemon reads it from the kernel, which can be after the write returned. A
watcher started right after a write can therefore receive that write's event.

Measured on the development Mac with a `WorkspaceEventWatcher` started immediately after
three fixture writes: the watcher's handler ran for 18 of 130 fixtures, 308 to 804 ms
after the watcher started, although nothing was written after it started. With another
process writing files elsewhere on the volume it ran for 23 of 30. The hosted app does
more between the writes and the watcher's start, and the rate there depends on the
machine: a fixture's watcher delivered such a hop for 5 of 30 fixtures in one run and for
3 of 40 under 24 busy loops, and for 0 of 120 in four runs on a quieter machine.

In the app that hop is a workspace refresh roughly 300 ms into the test. Its effects
match hosted CI failures on pull requests that did not touch the code involved:

- A disk inspection of the open document. Replace refuses with
  `externalObservationPending` while it runs (runs 37179939966, 37759400483, 39063145042
  and 42172519651).
- An authority-generation advance that supersedes a Replace All plan being prepared (runs
  39061438651 and 39063145042).
- A workspace reload. A Files pick is refused while its capture lags (run 39813122776).

Each test hit by this was patched on its own: a quiescence wait at the end of Replace
setup (#142), a readiness wait before the held Replace All press and a guard that drops
hops from a stopped watcher (#151), and a wait for the reload capture before the final
pick (#201). Those waits check the state at one moment. They cannot tell whether the
creation event has been delivered yet, so a test that awaits anything afterwards is still
exposed. `testHostedWriterRefusalAfterAuthorizationOnlyConverges` failed that way on
2026-11-06.

## Decision

`makeWorkspaceFixture(files:)`, the fixture every hosted gate test uses, calls
`WorkspaceFixtureEventSettle.settle(root:)` after its last write. `makeHostedEditorWorkspace`
calls it again after writing assets. A test that writes more files before opening the
workspace calls `settleFixtureFileSystemEvents(at:)` itself.

`settle` starts its own FSEvents stream on the root, makes and removes a sentinel
directory, and waits for the sentinel's removal to be delivered. FSEvents delivers events
in the order the kernel recorded them, so by then every earlier event has its number, and
a stream created later, whose "now" is a later number, cannot receive it. The wait is on
that condition and has no fixed delay. With the settle step the watcher's handler ran for
0 of 100 fixtures, 0 of 30 with the other process writing, and in the hosted app for 0 of
40 under the busy loops and 0 of 120 otherwise. The step took a median of 5 to 7 ms.

A settle that fails or times out (5 s) leaves the fixture usable, as it was before, and
adds a line to the test's timeout diagnostics.

The watcher stays live in every test, and no product code changes. The earlier per-test
waits stay: they also cover refreshes a test causes itself.

Alternatives:

- Stop the watcher in fixture setup and let tests opt back in. It removes the hop as
  well, but tests would then run without the component that delivers external changes in
  the app, and the tests that drive the watcher through
  `simulateDeliveredEventForTesting` need it live.
- Keep adding a quiescence wait to each test that fails. Four pull requests have done
  that; each wait closes one window and leaves the cause in place.
- A fixed delay between the fixture's writes and the open. It guesses at a latency that
  has no upper bound and slows every hosted test.
- `FSEventStreamFlushSync` on the product watcher after it starts. In a local probe a
  flush on a fresh stream returned before the late events were delivered (0 of 80
  detected), so it cannot serve as the barrier.
- Ignore events older than the watcher in `WorkspaceEventWatcher`. FSEvents gives the
  late event a number after the stream's start, so the product cannot tell it from a real
  change, and an extra refresh is harmless outside tests.
