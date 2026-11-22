# Adopt Swift tools 6.0 while retaining Swift 5 language mode

All eight packages and the iOS acceptance harness use Swift tools 6.0 and explicitly
select `swiftLanguageModes: [.v5]`. This separates the manifest/toolchain migration
from a later Swift 6 language-mode migration; strict-concurrency settings, deployment
targets and dependencies remain unchanged.

Package builds now require Swift 6.0 or newer, supplied by the already documented
Xcode 16+ minimum. The macOS CI jobs use the `macos-15` image and the iOS job uses
`macos-26`; both supply Xcode 16 or newer. No CI or Xcode minimum change is needed.
The Swift 5.10+ language entry in agent.md §2 describes the source language baseline,
not permission to build these manifests with a Swift 5 toolchain.

Alternatives:
- Keep tools 5.10: defers the first migration step rather than isolating it.
- Adopt Swift 6 language mode now: combines toolchain adoption with concurrency and
  source-behavior changes, outside this manifest-only step.
