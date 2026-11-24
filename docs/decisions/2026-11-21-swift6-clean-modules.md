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
(`Scripts/check-preview-webview-layering.py`) guards package sources, EditorKitTests,
and every Xcode test target whose `project.yml` settings select Swift 6, so a test
target is covered when it migrates. A `SWIFT_VERSION` that is a build-setting
reference, such as `$(inherited)`, is not expanded and counts as Swift 6. In these sources a direct `evaluateJavaScript`
call labels its `completionHandler:` argument (`nil` is allowed): the label tells
the overloads apart without parsing trailing closures or statements in Swift, and
it also catches an `async let` call that no `await` precedes.

Alternatives:
- Change package-wide defaults: also migrates tests outside this step's scope.
- Keep Swift 5 with strict concurrency: postpones compiler-enforced Swift 6 checks.
