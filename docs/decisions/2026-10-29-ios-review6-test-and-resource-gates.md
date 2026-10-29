# iOS review 6: asynchronous statistics observation and resource pins

The deferred-statistics input test waits for its matching editor snapshot through
XCTest's asynchronous `fulfillment(of:timeout:)`. It keeps the two-second limit,
requires both the edited text and its new statistics, and checks the session's
statistics afterward. Repeated matching snapshots are allowed. The test no longer
drives a nested main run loop or declares an unused `throws`.

Statistics still run off the main actor and return through the existing version
and text guards. Awaiting another task from the main actor suspends that actor's
job; it does not itself establish a main-thread deadlock. The implementation
comment describes the actual execution and stale-result guards.

The preview CI job checks all acceptance-resource digests immediately after
checkout. The manual iOS workflow remains the simulator, archive and IPA gate,
while an ordinary code PR now rejects stale resource pins on Linux. Updating
pins automatically during CI was rejected because that would hide a mismatch
between committed resources and the manifest under test.

Synchronizing main preserves its window ownership and SVG rules alongside this
PR's iOS search invalidation rules. Physical-device export, print and iCloud
acceptance remain separate.
