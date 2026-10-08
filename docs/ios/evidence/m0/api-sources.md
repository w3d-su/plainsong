# API verification — 2026-10-08

Context7 queried outside the sandbox using the required library → docs sequence.
No quota error. UIKit resolved to `/websites/developer_apple_uikit` (Apple, High
reputation); XcodeGen resolved to `/yonaskolb/xcodegen` (official project, High).
Queries covered iOS 26 TextKit 2 native composition/Undo, rendering attributes,
open-in-place file/folder grants/bookmarks, UIDocument saving/reverting and
independent generated app/XCTest/Info.plist/resources/scheme configuration.

Primary references:

- [UITextView TextKit 2 initializer](https://developer.apple.com/documentation/uikit/uitextview/init(usingtextlayoutmanager:))
- [TextKit 2 rendering attributes](https://developer.apple.com/documentation/uikit/nstextlayoutmanager/setrenderingattributes(_:for:))
- [UIDocument](https://developer.apple.com/documentation/uikit/uidocument)
- [UIDocument autosave](https://developer.apple.com/documentation/uikit/uidocument/autosave(completionhandler:))
- [Apple directory access guide](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)

Apple web pages exposed JS shells and Markdown links; this web reader could not
fetch their Markdown content. Directory/bookmark examples were obtained through
Context7 directly from Apple's directory guide. Concrete method signatures,
threading and safe-write hooks were additionally checked against installed
iPhoneOS 27 SDK headers `UITextView.h`, `NSTextLayoutManager.h`, `UIDocument.h`.
Generic test compilation confirms available SDK syntax, not runtime behavior on
iOS 26. In particular, autosave/close use the same serialized captured writer;
UIDocument contents snapshots cross queues under an NSLock; in-place provider
grant behavior and safe-write original URL semantics still require device proof.

No macOS security-scoped entitlement or `.withSecurityScope` bookmark option was
copied into iOS. This prototype uses `.minimalBookmark`, explicit start/stop scope
pairs and refuses stale resolution. No signing credentials or new dependencies.
