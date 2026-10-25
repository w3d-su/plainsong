# Retry a silent initial preview page once

Date: 2026-10-23. PR #209 follow-up; no frozen contract or bridge protocol change.

An initial page can remain unready without a navigation completion or a
WebContent termination callback. Retained traces observed loading=true and
progress0.1 without navigation callbacks before the deadline; their OS-level
cause is not established. Increasing test deadlines and owner cleanup alone
was insufficient: clean cc36bdb completed 181/181 once and 177/181 on a complete
unchanged-source repeat. Both results remain retained.

Arm one 2.5-second deadline after the first page load. If it is still unready,
uninvalidated and unterminated, and no render reached JavaScript or HTML export
is in flight, spend the retry before stopping/reloading the same bundled or
fallback page. Keep the newest pending render, its exact export render ID and
continuation, asset context and scroll barrier. Ready, invalidation and any
WebContent termination permanently retire this initial deadline. Existing live
termination recovery remains bounded separately; export termination still fails
typed. No per-case test retry, infinite page retry or new user flow is added.

The initial retry creates a new page generation and navigation token before
stopping the old load. Queued ready messages cannot flush a render during that
retry window: readiness must come from the current navigation's protocol probe.
An asynchronous probe from an older page cannot make the replacement ready.
The deadline weakly references its controller and rejects callbacks even after
cancellation. Tests control the scheduler and suppress page loads to reproduce
a silent initial entry deterministically, rather than waiting for a platform
race. Both bundled and fallback paths, synchronous scheduler reentrancy, stale
messages/probes, queued export IDs, active HTML export and bounded termination
recovery are covered.

ExportHTMLTestSupport now uses the common 8-second default. Functional
assertions, required-name admission and the zero-skip full-suite gate remain.
Complete repeated candidate runs are required; a passing subset or old head is
not stability closure. No preview-src or generated bundle change is needed.

Scene transitions also preserve a current unavailable reason until its writer
safely retires, or an explicit replacement grant successfully refreshes. A
retained close keeps its prior reason, session and admission. Grant revocation
during an await is not cleared by an older successful writer result.

## Evidence and causality boundary

Installed iOS27 runtime build24A5355p contains symbolic type references for
Gestures.GesturePhaseQueue and its private InvalidTransition type. The image
SHA-256 is 0fd8a9fc092a1570fce639549d73132b8ec4b295a9b2c3a2cf5889b82fc7f74f.
This verifies the type namespace, not execution at the failing test address or
an error-substitution mechanism. The earlier typed trace caught the custom
PreviewHostedTestWait timeout before XCTest displayed InvalidTransition.
Neither that ordering nor binary strings prove XCTest thread-local overwrite,
GPU IdleExit/PID=0 packet loss or a permanent WebKit startup defect. Those
causal explanations remain hypotheses until instrumented execution establishes
them. No private API or runtime hook is used by this implementation.

Apple documents the navigation object as identifying its load request and being
passed back through matching delegate callbacks; stopLoading cancels resource
loading. These support public navigation/probe fencing, not the proposed private
startup-race mechanism:

- [WKNavigation](https://developer.apple.com/documentation/webkit/wknavigation)
- [loadFileURL](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:))
- [stopLoading](https://developer.apple.com/documentation/webkit/wkwebview/stoploading())
- [WebContent termination callback](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:))

The Swift project's [historical willThrow issue](https://github.com/swiftlang/swift/issues/62348)
confirms a diagnostic hook used by testing frameworks. It was closed in 2022;
it is not evidence of the claimed current XCTest overwrite. Context7 returned
current Apple documentation; installed-runtime command/hash receipts remain in
the delivered evidence packet, separate from source and hardware acceptance.
