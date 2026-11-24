# Make Swift 6 the default language mode

With every first-party target migrated, set Swift 6 as the default in
`project.yml` and the first-party package manifests. Remove the per-target
Swift 6 overrides and the redundant `SWIFT_STRICT_CONCURRENCY` setting: Swift 6
already enforces strict concurrency. Dependencies keep their own language modes,
including Swift 5 for STTextView, STTextKitPlus, CoreTextSwift and SwiftTreeSitter.

The WebKit guard still checks package sources and resolves Swift 6 Xcode test
targets using the project default when the target has no override. It now checks
all first-party Swift package tests for the async `evaluateJavaScript` import,
not just EditorKitTests. The mixed-language bridging issue still matters because
dependencies may build in Swift 5.

Alternatives:
- Keep per-target overrides: duplicates the same setting and lets new targets
  fall back to the old default.
- Keep the guard limited to EditorKitTests: leaves other Swift 6 package tests
  unguarded.

Supersedes the per-target defaults and package test guard scope in
[Adopt Swift 6 for concurrency-clean targets](2026-11-21-swift6-clean-modules.md).
