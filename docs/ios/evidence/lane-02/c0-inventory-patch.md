# Lane 13 inventory patch for SyntaxKit

Lane 02 changed `Packages/SyntaxKit/Package.swift` and `Packages/EditorKit/Package.swift`. It did not edit `EditorReplaceLayeringTests.swift`, `docs/decision-log.md`, or `agent.md`. Those stay with lane 13.

## Decision Log row to append

| Date | Decision | Why | Alternatives |
|---|---|---|---|
| 2026-10-08 | SyntaxKit owns SwiftTreeSitter 0.10.0, tree-sitter-markdown 0.5.3, and the vendored TSX and YAML C targets. EditorKit depends on SyntaxKit and no longer compiles those grammars. | Mac and iOS must share one parser, and the same grammar symbols must be linked once. | Leave the parser in EditorKit and copy it for iOS. Link the C targets from both packages. |

## `testNoProjectOrPackageDependencyChange` expected package lines

Replace the EditorKit and SyntaxKit entries with:

```swift
"EditorKit": [
    #".package(path: "../MarkdownCore")"#,
    #".package(path: "../SyntaxKit")"#,
    #".package(url: "https://github.com/krzyzanowskim/STTextView.git", exact: "2.3.10")"#,
],
"SyntaxKit": [
    #".package(path: "../MarkdownCore")"#,
    #".package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", exact: "0.10.0")"#,
    #".package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown.git", exact: "0.5.3")"#,
],
```

Leave every other package list, project target, dependency, and npm inventory as C0 recorded them. No new third-party version was introduced. The revisions stay `f97df585296977d8fcaf644cbde567151d1367b8` and `f969cd3ae3f9fbd4e43205431d0ae286014c05b5`.

Until this patch lands, that one assertion fails. The other layering assertions on this branch passed.
