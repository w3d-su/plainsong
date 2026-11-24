# Adopt Swift 6 for concurrency-clean targets

Select Swift 6 language mode per target for MarkdownCore, SyntaxKit and its tests,
WorkspaceCore and its tests, WorkspaceKit, PreviewKit, PreviewKitContracts,
WorkspaceKitIOS, IOSAcceptanceHarness and its tests, and IOSPreviewTestHost.
Package defaults remain Swift 5 so other targets can migrate independently.
Swift 6 replaces the migrated targets' experimental strict-concurrency setting
with mandatory concurrency checking.

This continues the tools-version migration in PR #284 without changing dependencies,
deployment targets, or the language mode of parallel migration lanes. Three source
changes were needed: `DocumentSession`'s statistics callbacks become `@Sendable`, and
PreviewKit awaits `evaluateJavaScript` through the completion-handler wrapper
`evaluateJavaScriptReply(_:)`. The async import's bridging thunk is shared across
modules, and a Swift 6 and a Swift 5 module in one binary disagreed about it
(SIGSEGV in PreviewKitTests with Xcode 16.4). `make check-preview-layering`
(`Scripts/check-preview-webview-layering.py`) rejects awaits of the async import in
package sources; widen it when a test target or AppTests moves to Swift 6.
EditorKitTests and PlainsongIOSTests are also covered. In these guarded sources,
direct calls label `completionHandler:` so the check can distinguish overloads
without parsing trailing closures or statements in Swift.

Alternatives:
- Change package-wide defaults: also migrates tests outside this step's scope.
- Keep Swift 5 with strict concurrency: postpones compiler-enforced Swift 6 checks.
