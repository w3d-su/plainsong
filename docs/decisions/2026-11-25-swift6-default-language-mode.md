# Make Swift 6 the default language mode

`project.yml` sets `SWIFT_VERSION: "6"` in the project-level settings, and the nine
targets no longer repeat it. The package manifests (MarkdownCore, EditorKit,
PreviewKit, WorkspaceKit, SyntaxKit, WorkspaceCore, WorkspaceKitIOS, and the iOS
acceptance harness) select `swiftLanguageModes: [.v6]` and drop their per-target
`.swiftLanguageMode(.v6)` settings. EditorKitIOS already had the package-wide setting.
The project-level `SWIFT_STRICT_CONCURRENCY: complete` is removed.

Every Swift target moved to Swift 6 one at a time, ending with #307, #308 and #309, so
the Swift 5 defaults no longer applied to anything. No target changes language mode in
this step: before the edit, every target in `project.yml` overrode the base with `"6"`,
and every Swift target in each manifest set `.swiftLanguageMode(.v6)`. SyntaxKit's
`TreeSitterTSXFixed` and `TreeSitterYAMLFixed` targets compile only C, so a language
mode does not apply to them. With the default flipped, a new target is Swift 6 without
remembering an override.

`SWIFT_STRICT_CONCURRENCY` does nothing in Swift 6 mode. Xcode's `Swift.xcspec`
applies it only when `EFFECTIVE_SWIFT_VERSION` is 4, 4.2 or 5. Its description says
Swift 6 mode always checks completely and reports errors. Keeping it would only
suggest the setting still decides something.

`Scripts/check-preview-webview-layering.py` already resolves a test target's
`SWIFT_VERSION` from the project-level settings when the target sets none, so every
Xcode test target is still guarded as Swift 6.

`Prototypes/iOSM0/project.yml` is a separate prototype project on Swift 5.10. Changing
it would change its language mode, so it is outside this step.

Alternatives:
- Keep the Swift 5 defaults and per-target overrides: a new target would silently build
  in Swift 5, and the redundant settings outnumber the real ones.
- Keep `SWIFT_STRICT_CONCURRENCY: complete` for a target that later opts back to Swift 5:
  such a target needs its own decision, which can set the checking it wants.

Supersedes: the Swift 5 package default in `2026-11-20-swift-tools-6-language-mode-v5.md`,
and the per-target selection in `2026-11-21-swift6-clean-modules.md` and
`2026-11-24-swift6-macos-app.md`.
