# Lane 02 iOS compile

Recorded 2026-10-08. This is a simulator compile. It is not a real-device run.

## Package

```sh
swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --triple arm64-apple-ios26.0-simulator
```

Run from `Packages/SyntaxKit`. SDK: `iPhoneSimulator27.0.sdk`. Result: **build complete**. The product is the SyntaxKit target only, with SwiftTreeSitter, tree-sitter-markdown, and the vendored TSX/YAML targets.

## App scaffold

```sh
make ios-c0-build
```

`Scripts/ios/c0.sh build` held `/private/tmp/plainsong-xcodebuild-test.lock`. Xcode 27.0 (`27A5194q`), simulator SDK 27.0, destination `generic/platform=iOS Simulator`, deployment 26.0, `CODE_SIGNING_ALLOWED=NO`. Scheme `PlainsongIOS`, `build-for-testing`.

Result: **TEST BUILD SUCCEEDED**. Artifact:

`/private/tmp/plainsong-ios-c0/642cb212703220409874a2741c5adbfb8c80fe8a-build.YL4KOc`

`source.json` records `sourceSHA` `642cb212703220409874a2741c5adbfb8c80fe8a` and `dirty: true`, because this compile ran before the lane commit. Parser objects exist for both `arm64` and `x86_64` simulator slices:

- `.../SyntaxKit.build/Debug-iphonesimulator/SyntaxKit-t.build/Objects-normal/arm64/MarkdownSyntaxParser.o`
- `.../SyntaxKit.build/Debug-iphonesimulator/SyntaxKit-t.build/Objects-normal/x86_64/MarkdownSyntaxParser.o`

Those SyntaxKit objects do not reference AppKit, UIKit, or STTextView. `PlainsongIOS` links `SyntaxKit-product` and does not link EditorKit.

## Not claimed

- No `ios-c0-test` execution. The new differential and provider tests ran on the Mac `swift test` host.
- No installed-device or owner-signed run.
- No IME, Files, iCloud, or on-device performance budget.
