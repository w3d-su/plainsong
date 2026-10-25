# Limit the silent initial preview retry to iOS

Date: 2026-10-25. Review H5 on PR #210; integration owner repair after lane handoff.

## Decision

Enable the one-shot 2.5-second silent-initial-page deadline only on iOS by default.
The internal initializer can select that policy for deterministic tests on either
platform. macOS does not install the deadline or apply its navigation-token gate
when its normal `didFinish` callback probes readiness. Existing WebContent
termination recovery is unchanged on both platforms.

`loadFileURL` returns an optional `WKNavigation`. After an iOS retry without a
navigation token, a legal bridge ready message requests a protocol probe against
the current page. It does not directly flush pending work: the ready message may
have been queued by the stopped page. Both that fallback and `didFinish` capture
the current page generation when evaluating JavaScript; a later reload or
invalidation rejects their replies. In the nil-token fallback, readiness means
that the currently installed page answers the public protocol probe, rather than
claiming a navigation completion that WebKit did not identify. A wrong protocol
remains unready. No second
initial retry or changed timeout is introduced.

## Why and alternatives

The prior initial-load retry was motivated by recorded iOS startup failures; it
had no Mac cold-start measurement justifying an additional stop/reload. Keeping
it enabled on Mac would change startup under load. A shared platform-default
policy preserves Mac startup while allowing the exact iOS policy to be exercised
by package tests on Mac.

Blindly accepting bridge ready whenever the navigation token is nil would avoid
the hang but admit stale stopped-page messages. Requiring only a matching
`didFinish` leaves a nil-token load without a readiness path. The current-page
probe preserves the generation fence and lets a valid replacement become ready.
No bridge protocol, bundled JavaScript, frozen iOS contract, parser or typing
path changes. Physical-device readiness and measured performance remain separate
gates; tests do not claim to reproduce private WebKit causes.

## Validation

The five `PreviewInitialReadinessPolicyTests` are required by the iOS Preview
manifest. They cover platform default, explicitly disabled policy, nil-navigation
ready/wrong-protocol behavior with an exact queued render, and superseded or
invalidated asynchronous replies, plus rejection of a foreign web view or
nonmatching nonnil navigation. Existing one-retry, queued-export and bounded
termination cases remain required. Native execution is recorded separately by
the integration owner; this entry does not claim a passing run before execution.

Current official WebKit documentation was retrieved through Context7:

- [loadFileURL(_:allowingReadAccessTo:)](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) declares `WKNavigation?`.
- [WKNavigation](https://developer.apple.com/documentation/webkit/wknavigation) identifies a specific page load and its matching delegate callbacks.
