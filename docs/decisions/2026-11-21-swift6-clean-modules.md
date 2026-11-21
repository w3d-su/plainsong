# Adopt Swift 6 for concurrency-clean targets

Select Swift 6 language mode per target for MarkdownCore, SyntaxKit and its tests,
WorkspaceCore and its tests, WorkspaceKit, PreviewKit, PreviewKitContracts,
WorkspaceKitIOS, IOSAcceptanceHarness and its tests, and IOSPreviewTestHost.
Package defaults remain Swift 5 so other targets can migrate independently.
Swift 6 replaces the migrated targets' experimental strict-concurrency setting
with mandatory concurrency checking.

This continues the tools-version migration in PR #284 without changing source,
dependencies, deployment targets, or the language mode of parallel migration lanes.

Alternatives:
- Change package-wide defaults: also migrates tests outside this step's scope.
- Keep Swift 5 with strict concurrency: postpones compiler-enforced Swift 6 checks.
